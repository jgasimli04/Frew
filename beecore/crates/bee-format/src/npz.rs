//! Minimal npy/npz reader-writer, compatible with `numpy.savez_compressed` /
//! `numpy.load(allow_pickle=False)`.
//!
//! The `.bee` v0 side-channel section (`helix_arrays`) is literally the bytes
//! numpy writes: a zip archive of `<name>.npy` members, deflate-compressed.
//! That subset of zip is small and stable, so it is implemented here directly
//! rather than pulling in a general zip dependency — this crate has to stay
//! trivially cross-compilable (iOS/Android/desktop) and auditable at the byte
//! level.
//!
//! Limitations (fine for side-channel sizes, enforced with clear errors):
//! zip64 is not supported; only STORED and DEFLATE members are read.

use crate::error::{Error, Result};

// ---------------------------------------------------------------------------
// npy (one array)
// ---------------------------------------------------------------------------

const NPY_MAGIC: &[u8; 6] = b"\x93NUMPY";

#[derive(Debug, Clone, PartialEq)]
pub struct NpyArray {
    /// numpy descr string, e.g. "<f4".
    pub descr: String,
    pub fortran_order: bool,
    pub shape: Vec<usize>,
    /// Raw element bytes, C-order.
    pub data: Vec<u8>,
}

impl NpyArray {
    pub fn f32(shape: Vec<usize>, values: &[f32]) -> Result<NpyArray> {
        let n: usize = shape.iter().product();
        if n != values.len() {
            return Err(Error::Format(format!(
                "npy shape {shape:?} does not match {} values",
                values.len()
            )));
        }
        let mut data = Vec::with_capacity(values.len() * 4);
        for &v in values {
            data.extend_from_slice(&v.to_le_bytes());
        }
        Ok(NpyArray { descr: "<f4".into(), fortran_order: false, shape, data })
    }

    pub fn itemsize(&self) -> Result<usize> {
        // descr like "<f4", "<i2", "|u1": trailing digits are the byte width.
        let digits: String =
            self.descr.chars().skip_while(|c| !c.is_ascii_digit()).collect();
        digits
            .parse::<usize>()
            .map_err(|_| Error::Format(format!("unsupported npy descr {:?}", self.descr)))
    }

    pub fn elem_count(&self) -> usize {
        self.shape.iter().product()
    }

    pub fn as_f32(&self) -> Result<Vec<f32>> {
        if self.descr != "<f4" {
            return Err(Error::Format(format!(
                "expected little-endian float32 npy (<f4), got {:?}",
                self.descr
            )));
        }
        if self.fortran_order {
            return Err(Error::Format("fortran-order npy not supported".into()));
        }
        Ok(self
            .data
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect())
    }
}

/// Extract the value that follows `'key':` in a numpy header dict literal.
fn header_field<'a>(header: &'a str, key: &str) -> Result<&'a str> {
    let pat = format!("'{key}':");
    let at = header
        .find(&pat)
        .ok_or_else(|| Error::Format(format!("npy header missing {key:?}: {header}")))?;
    Ok(header[at + pat.len()..].trim_start())
}

pub fn parse_npy(bytes: &[u8]) -> Result<NpyArray> {
    if bytes.len() < 10 || &bytes[..6] != NPY_MAGIC {
        return Err(Error::Format("not an npy array (bad magic)".into()));
    }
    let (major, _minor) = (bytes[6], bytes[7]);
    let (hlen, hstart) = match major {
        1 => (u16::from_le_bytes([bytes[8], bytes[9]]) as usize, 10),
        2 => {
            if bytes.len() < 12 {
                return Err(Error::Format("truncated npy v2 header".into()));
            }
            (u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]) as usize, 12)
        }
        v => return Err(Error::Format(format!("unsupported npy version {v}"))),
    };
    let hend = hstart + hlen;
    if bytes.len() < hend {
        return Err(Error::Format("truncated npy header".into()));
    }
    let header = std::str::from_utf8(&bytes[hstart..hend])
        .map_err(|_| Error::Format("npy header is not utf-8".into()))?;

    // descr: the next quoted string
    let rest = header_field(header, "descr")?;
    let quote = rest
        .chars()
        .next()
        .filter(|&c| c == '\'' || c == '"')
        .ok_or_else(|| Error::Format(format!("bad npy descr in header: {header}")))?;
    let descr_end = rest[1..]
        .find(quote)
        .ok_or_else(|| Error::Format(format!("unterminated npy descr: {header}")))?;
    let descr = rest[1..1 + descr_end].to_string();

    let fortran_order = header_field(header, "fortran_order")?.starts_with("True");

    let rest = header_field(header, "shape")?;
    if !rest.starts_with('(') {
        return Err(Error::Format(format!("bad npy shape in header: {header}")));
    }
    let close = rest
        .find(')')
        .ok_or_else(|| Error::Format(format!("unterminated npy shape: {header}")))?;
    let mut shape = Vec::new();
    for part in rest[1..close].split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        shape.push(
            part.parse::<usize>()
                .map_err(|_| Error::Format(format!("bad npy shape dim {part:?}")))?,
        );
    }

    let arr = NpyArray {
        descr,
        fortran_order,
        shape,
        data: bytes[hend..].to_vec(),
    };
    let expect = arr.elem_count() * arr.itemsize()?;
    if arr.data.len() != expect {
        return Err(Error::Format(format!(
            "npy data length {} != shape {:?} * itemsize (expected {expect})",
            arr.data.len(),
            arr.shape
        )));
    }
    Ok(arr)
}

pub fn write_npy(a: &NpyArray) -> Vec<u8> {
    // Reproduce numpy's v1.0 header formatting exactly (dict literal, space
    // padding to a 64-byte-aligned total, trailing newline).
    let shape = match a.shape.len() {
        1 => format!("({},)", a.shape[0]),
        _ => format!(
            "({})",
            a.shape.iter().map(|d| d.to_string()).collect::<Vec<_>>().join(", ")
        ),
    };
    let mut header = format!(
        "{{'descr': '{}', 'fortran_order': {}, 'shape': {}, }}",
        a.descr,
        if a.fortran_order { "True" } else { "False" },
        shape
    );
    let unpadded = 10 + header.len() + 1; // magic+ver+hlen, header, '\n'
    let pad = (64 - unpadded % 64) % 64;
    header.push_str(&" ".repeat(pad));
    header.push('\n');

    let mut out = Vec::with_capacity(10 + header.len() + a.data.len());
    out.extend_from_slice(NPY_MAGIC);
    out.extend_from_slice(&[1u8, 0u8]);
    out.extend_from_slice(&(header.len() as u16).to_le_bytes());
    out.extend_from_slice(header.as_bytes());
    out.extend_from_slice(&a.data);
    out
}

// ---------------------------------------------------------------------------
// npz (zip of npy members)
// ---------------------------------------------------------------------------

const LOCAL_SIG: u32 = 0x0403_4b50;
const CENTRAL_SIG: u32 = 0x0201_4b50;
const EOCD_SIG: u32 = 0x0605_4b50;

fn u16_at(b: &[u8], at: usize) -> Result<u16> {
    b.get(at..at + 2)
        .map(|s| u16::from_le_bytes([s[0], s[1]]))
        .ok_or_else(|| Error::Format("truncated zip structure".into()))
}

fn u32_at(b: &[u8], at: usize) -> Result<u32> {
    b.get(at..at + 4)
        .map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
        .ok_or_else(|| Error::Format("truncated zip structure".into()))
}

/// Read an npz: returns `(member_name_without_.npy, array)` in archive order.
pub fn read_npz(bytes: &[u8]) -> Result<Vec<(String, NpyArray)>> {
    // Locate the end-of-central-directory record (scan back over the comment).
    let mut eocd = None;
    let lo = bytes.len().saturating_sub(22 + 65_536);
    let mut at = bytes.len().saturating_sub(22);
    loop {
        if u32_at(bytes, at)? == EOCD_SIG {
            eocd = Some(at);
            break;
        }
        if at == lo {
            break;
        }
        at -= 1;
    }
    let eocd = eocd.ok_or_else(|| Error::Format("not a zip/npz (no end record)".into()))?;
    let n_entries = u16_at(bytes, eocd + 10)? as usize;
    let cd_offset = u32_at(bytes, eocd + 16)? as usize;
    if cd_offset == 0xFFFF_FFFF || n_entries == 0xFFFF {
        return Err(Error::Format("zip64 npz not supported (v0)".into()));
    }

    let mut out = Vec::with_capacity(n_entries);
    let mut at = cd_offset;
    for _ in 0..n_entries {
        if u32_at(bytes, at)? != CENTRAL_SIG {
            return Err(Error::Format("bad zip central directory entry".into()));
        }
        let method = u16_at(bytes, at + 10)?;
        let crc = u32_at(bytes, at + 16)?;
        let csize = u32_at(bytes, at + 20)? as usize;
        let usize_ = u32_at(bytes, at + 24)? as usize;
        let nlen = u16_at(bytes, at + 28)? as usize;
        let xlen = u16_at(bytes, at + 30)? as usize;
        let clen = u16_at(bytes, at + 32)? as usize;
        let lho = u32_at(bytes, at + 42)? as usize;
        if csize == 0xFFFF_FFFF || usize_ == 0xFFFF_FFFF || lho == 0xFFFF_FFFF {
            return Err(Error::Format("zip64 npz not supported (v0)".into()));
        }
        let name = std::str::from_utf8(
            bytes
                .get(at + 46..at + 46 + nlen)
                .ok_or_else(|| Error::Format("truncated zip name".into()))?,
        )
        .map_err(|_| Error::Format("non-utf8 zip member name".into()))?
        .to_string();
        at += 46 + nlen + xlen + clen;

        if name.ends_with('/') {
            continue; // directory entry
        }

        // Local header: its name/extra lengths may differ from the central ones.
        if u32_at(bytes, lho)? != LOCAL_SIG {
            return Err(Error::Format("bad zip local header".into()));
        }
        let lnlen = u16_at(bytes, lho + 26)? as usize;
        let lxlen = u16_at(bytes, lho + 28)? as usize;
        let dstart = lho + 30 + lnlen + lxlen;
        let cdata = bytes
            .get(dstart..dstart + csize)
            .ok_or_else(|| Error::Format("truncated zip member data".into()))?;

        let data = match method {
            0 => cdata.to_vec(),
            8 => miniz_oxide::inflate::decompress_to_vec(cdata).map_err(|e| {
                Error::Format(format!("npz member {name:?} failed to inflate: {e:?}"))
            })?,
            m => {
                return Err(Error::Format(format!(
                    "npz member {name:?} uses unsupported zip method {m}"
                )))
            }
        };
        if data.len() != usize_ {
            return Err(Error::Format(format!(
                "npz member {name:?}: size {} != declared {usize_}",
                data.len()
            )));
        }
        if crc32fast::hash(&data) != crc {
            return Err(Error::Format(format!("npz member {name:?}: crc mismatch")));
        }

        let key = name.strip_suffix(".npy").unwrap_or(&name).to_string();
        out.push((key, parse_npy(&data)?));
    }
    Ok(out)
}

/// Write an npz numpy can `np.load`: deflated members named `<name>.npy`.
/// Deterministic output (fixed timestamps) so tests can compare bytes.
pub fn write_npz(entries: &[(&str, &NpyArray)]) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut central = Vec::new();
    // DOS date 1980-01-01, time 00:00 — the zip epoch, accepted by zipfile.
    let (dos_time, dos_date) = (0u16, 0x0021u16);

    for (name, arr) in entries {
        let member = format!("{name}.npy");
        let raw = write_npy(arr);
        let crc = crc32fast::hash(&raw);
        let deflated = miniz_oxide::deflate::compress_to_vec(&raw, 6);
        let lho = out.len();
        if raw.len() > u32::MAX as usize || lho > u32::MAX as usize {
            return Err(Error::Format("npz too large (zip64 unsupported in v0)".into()));
        }

        out.extend_from_slice(&LOCAL_SIG.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes()); // version needed
        out.extend_from_slice(&0u16.to_le_bytes()); // flags
        out.extend_from_slice(&8u16.to_le_bytes()); // method: deflate
        out.extend_from_slice(&dos_time.to_le_bytes());
        out.extend_from_slice(&dos_date.to_le_bytes());
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&(deflated.len() as u32).to_le_bytes());
        out.extend_from_slice(&(raw.len() as u32).to_le_bytes());
        out.extend_from_slice(&(member.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // extra len
        out.extend_from_slice(member.as_bytes());
        out.extend_from_slice(&deflated);

        central.extend_from_slice(&CENTRAL_SIG.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes()); // version made by
        central.extend_from_slice(&20u16.to_le_bytes()); // version needed
        central.extend_from_slice(&0u16.to_le_bytes()); // flags
        central.extend_from_slice(&8u16.to_le_bytes()); // method
        central.extend_from_slice(&dos_time.to_le_bytes());
        central.extend_from_slice(&dos_date.to_le_bytes());
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&(deflated.len() as u32).to_le_bytes());
        central.extend_from_slice(&(raw.len() as u32).to_le_bytes());
        central.extend_from_slice(&(member.len() as u16).to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes()); // extra len
        central.extend_from_slice(&0u16.to_le_bytes()); // comment len
        central.extend_from_slice(&0u16.to_le_bytes()); // disk number
        central.extend_from_slice(&0u16.to_le_bytes()); // internal attrs
        central.extend_from_slice(&0u32.to_le_bytes()); // external attrs
        central.extend_from_slice(&(lho as u32).to_le_bytes());
        central.extend_from_slice(member.as_bytes());
    }

    let cd_offset = out.len();
    out.extend_from_slice(&central);
    if out.len() > u32::MAX as usize {
        return Err(Error::Format("npz too large (zip64 unsupported in v0)".into()));
    }
    out.extend_from_slice(&EOCD_SIG.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // this disk
    out.extend_from_slice(&0u16.to_le_bytes()); // cd start disk
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(central.len() as u32).to_le_bytes());
    out.extend_from_slice(&(cd_offset as u32).to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // comment len
    Ok(out)
}
