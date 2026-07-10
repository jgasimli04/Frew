//! Emit + dataset ingest. All hand-rolled and dependency-light on purpose:
//! the record emit (npy/npz) is a few dozen lines of stable spec, and owning
//! it keeps the crate honest about exactly what lands on disk.
//!
//! Readers cover the three public run-to-failure / seeded-fault corpora the
//! runner binaries consume (bench/fetch_data.sh):
//!  * NASA IMS: whitespace-separated ASCII, one column per accelerometer;
//!  * CWRU: MATLAB v5 .mat files (incl. miCOMPRESSED), arrays named *_DE_time
//!    / *_FE_time;
//!  * FEMTO/PRONOSTIA: acc_XXXXX.csv, h/m/s/µs then horiz + vert channels.

use std::io::Write as _;
use std::path::Path;

// ---------------------------------------------------------------------------
// npy / npz writing (spec: numpy format 1.0; zip: stored entries only)
// ---------------------------------------------------------------------------

/// Serialise a 1-D f64 array as .npy bytes (format 1.0, little endian).
pub fn npy_bytes_f64(data: &[f64]) -> Vec<u8> {
    let header_dict = format!("{{'descr': '<f8', 'fortran_order': False, 'shape': ({},), }}", data.len());
    let mut header = header_dict.into_bytes();
    // pad with spaces so magic+2+2+header is a multiple of 64, newline-terminated
    let base = 6 + 2 + 2;
    let total = ((base + header.len() + 1 + 63) / 64) * 64;
    header.resize(total - base - 1, b' ');
    header.push(b'\n');

    let mut out = Vec::with_capacity(total + data.len() * 8);
    out.extend_from_slice(b"\x93NUMPY");
    out.push(1);
    out.push(0);
    out.extend_from_slice(&(header.len() as u16).to_le_bytes());
    out.extend_from_slice(&header);
    for v in data {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out
}

fn crc32(data: &[u8]) -> u32 {
    // IEEE 802.3 table-less bitwise CRC-32 (small inputs; clarity over speed)
    let mut crc = 0xFFFF_FFFFu32;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

/// Write an .npz (zip of stored .npy entries) — numpy's np.load reads it.
pub fn write_npz(path: &Path, arrays: &[(&str, &[f64])]) -> std::io::Result<()> {
    let mut file = std::fs::File::create(path)?;
    let mut central: Vec<u8> = Vec::new();
    let mut offset = 0u32;
    let mut count = 0u16;

    for (name, data) in arrays {
        let bytes = npy_bytes_f64(data);
        let fname = format!("{name}.npy");
        let crc = crc32(&bytes);
        let (sz, nlen) = (bytes.len() as u32, fname.len() as u16);

        let mut local: Vec<u8> = Vec::new();
        local.extend_from_slice(&0x04034b50u32.to_le_bytes());
        local.extend_from_slice(&20u16.to_le_bytes()); // version needed
        local.extend_from_slice(&0u16.to_le_bytes()); // flags
        local.extend_from_slice(&0u16.to_le_bytes()); // method: stored
        local.extend_from_slice(&0u32.to_le_bytes()); // dos time+date
        local.extend_from_slice(&crc.to_le_bytes());
        local.extend_from_slice(&sz.to_le_bytes()); // compressed
        local.extend_from_slice(&sz.to_le_bytes()); // uncompressed
        local.extend_from_slice(&nlen.to_le_bytes());
        local.extend_from_slice(&0u16.to_le_bytes()); // extra len
        local.extend_from_slice(fname.as_bytes());
        file.write_all(&local)?;
        file.write_all(&bytes)?;

        central.extend_from_slice(&0x02014b50u32.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes()); // made by
        central.extend_from_slice(&20u16.to_le_bytes()); // needed
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u32.to_le_bytes());
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&sz.to_le_bytes());
        central.extend_from_slice(&sz.to_le_bytes());
        central.extend_from_slice(&nlen.to_le_bytes());
        // extra(2) + comment(2) + disk(2) + internal attrs(2) + external attrs(4)
        central.extend_from_slice(&[0u8; 12]);
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(fname.as_bytes());

        offset += (local.len() + bytes.len()) as u32;
        count += 1;
    }

    file.write_all(&central)?;
    let mut eocd: Vec<u8> = Vec::new();
    eocd.extend_from_slice(&0x06054b50u32.to_le_bytes());
    eocd.extend_from_slice(&[0u8; 4]); // disk numbers
    eocd.extend_from_slice(&count.to_le_bytes());
    eocd.extend_from_slice(&count.to_le_bytes());
    eocd.extend_from_slice(&(central.len() as u32).to_le_bytes());
    eocd.extend_from_slice(&offset.to_le_bytes());
    eocd.extend_from_slice(&0u16.to_le_bytes()); // comment
    file.write_all(&eocd)
}

/// Plain CSV with a header row; every column same length.
pub fn write_csv(path: &Path, cols: &[(&str, &[f64])]) -> std::io::Result<()> {
    let mut f = std::fs::File::create(path)?;
    writeln!(f, "{}", cols.iter().map(|c| c.0).collect::<Vec<_>>().join(","))?;
    let n = cols.first().map(|c| c.1.len()).unwrap_or(0);
    for i in 0..n {
        let row: Vec<String> = cols.iter().map(|c| format!("{}", c.1[i])).collect();
        writeln!(f, "{}", row.join(","))?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// dataset readers
// ---------------------------------------------------------------------------

/// NASA IMS snapshot file: whitespace-separated columns of accelerometer
/// readings (already in volts ≈ g). Returns the chosen column.
pub fn read_ims(path: &Path, channel: usize) -> std::io::Result<Vec<f64>> {
    let text = std::fs::read_to_string(path)?;
    Ok(text
        .lines()
        .filter_map(|l| l.split_whitespace().nth(channel).and_then(|v| v.parse::<f64>().ok()))
        .collect())
}

/// FEMTO/PRONOSTIA acc_XXXXX.csv: h,m,s,µs,horiz,vert (comma or semicolon).
/// channel 0 = horizontal (col 4), 1 = vertical (col 5).
pub fn read_femto_acc(path: &Path, channel: usize) -> std::io::Result<Vec<f64>> {
    let text = std::fs::read_to_string(path)?;
    let col = 4 + channel.min(1);
    Ok(text
        .lines()
        .filter_map(|l| {
            let sep = if l.contains(';') { ';' } else { ',' };
            l.split(sep).nth(col).and_then(|v| v.trim().parse::<f64>().ok())
        })
        .collect())
}

// --- MATLAB v5 (.mat) subset: what the CWRU corpus needs -------------------

/// Parse a MATLAB v5 .mat file and return (name, data) for every real f64
/// matrix, flattened. Handles miCOMPRESSED elements (zlib) via miniz.
pub fn read_mat_v5(path: &Path) -> std::io::Result<Vec<(String, Vec<f64>)>> {
    let raw = std::fs::read(path)?;
    if raw.len() < 128 {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "short .mat"));
    }
    // header: 116 text + 8 subsys + u16 version + "IM" endian flag
    let mut out = Vec::new();
    let mut pos = 128usize;
    while pos + 8 <= raw.len() {
        let (dtype, dsize, data_off, elem_size) = mat_tag(&raw, pos)?;
        let body = &raw[data_off..data_off + dsize];
        if dtype == 15 {
            // miCOMPRESSED: zlib stream containing one element
            let inflated = miniz_oxide::inflate::decompress_to_vec_zlib(body)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, format!("{e:?}")))?;
            if let Some(pair) = parse_matrix_element(&inflated, 0)? {
                out.push(pair);
            }
        } else if dtype == 14 {
            if let Some(pair) = parse_matrix_element(&raw, pos)? {
                out.push(pair);
            }
        }
        pos += elem_size;
    }
    Ok(out)
}

/// CWRU convenience: the drive-end (or fan-end) time series from a .mat file.
pub fn read_cwru(path: &Path, key_suffix: &str) -> std::io::Result<Vec<f64>> {
    let all = read_mat_v5(path)?;
    all.iter()
        .find(|(name, _)| name.ends_with(key_suffix))
        .map(|(_, v)| v.clone())
        .ok_or_else(|| {
            let names: Vec<&str> = all.iter().map(|(n, _)| n.as_str()).collect();
            std::io::Error::new(
                std::io::ErrorKind::NotFound,
                format!("no *{key_suffix} in {path:?}; arrays: {names:?}"),
            )
        })
}

/// Tag at `pos` → (type, size, data offset, total element size incl. padding).
fn mat_tag(raw: &[u8], pos: usize) -> std::io::Result<(u32, usize, usize, usize)> {
    let word = u32::from_le_bytes(raw[pos..pos + 4].try_into().unwrap());
    if word >> 16 != 0 {
        // small element: type in low 16 bits, size in high 16, data in next 4
        let dtype = word & 0xFFFF;
        let dsize = (word >> 16) as usize;
        Ok((dtype, dsize, pos + 4, 8))
    } else {
        let dsize = u32::from_le_bytes(raw[pos + 4..pos + 8].try_into().unwrap()) as usize;
        let padded = (dsize + 7) / 8 * 8;
        Ok((word, dsize, pos + 8, 8 + padded))
    }
}

/// Parse a miMATRIX element at `pos`; return (name, flattened f64 data) if it
/// is a real numeric matrix.
fn parse_matrix_element(raw: &[u8], pos: usize) -> std::io::Result<Option<(String, Vec<f64>)>> {
    let (dtype, dsize, off, _) = mat_tag(raw, pos)?;
    if dtype != 14 {
        return Ok(None);
    }
    let end = off + dsize;
    let mut p = off;
    // subelement 1: array flags (skip; we accept any numeric class)
    let (_, _, o, sz) = mat_tag(raw, p)?;
    let _ = o;
    p += sz;
    // subelement 2: dimensions
    let (_, _, _, sz) = mat_tag(raw, p)?;
    p += sz;
    // subelement 3: array name (miINT8)
    let (_, nsz, noff, sz) = mat_tag(raw, p)?;
    let name = String::from_utf8_lossy(&raw[noff..noff + nsz]).to_string();
    p += sz;
    if p >= end {
        return Ok(Some((name, Vec::new())));
    }
    // subelement 4: real part
    let (vtype, vsz, voff, _) = mat_tag(raw, p)?;
    let body = &raw[voff..voff + vsz];
    let data: Vec<f64> = match vtype {
        9 => body.chunks_exact(8).map(|c| f64::from_le_bytes(c.try_into().unwrap())).collect(),
        7 => body.chunks_exact(4).map(|c| f32::from_le_bytes(c.try_into().unwrap()) as f64).collect(),
        5 => body.chunks_exact(4).map(|c| i32::from_le_bytes(c.try_into().unwrap()) as f64).collect(),
        3 => body.chunks_exact(2).map(|c| i16::from_le_bytes(c.try_into().unwrap()) as f64).collect(),
        _ => return Ok(Some((name, Vec::new()))),
    };
    Ok(Some((name, data)))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a minimal uncompressed MATLAB v5 file in memory and parse it.
    #[test]
    fn mat_v5_roundtrip_on_a_synthetic_file() {
        let mut f = Vec::new();
        let mut text = b"MATLAB 5.0 MAT-file, synthetic fixture".to_vec();
        text.resize(116, b' ');
        f.extend_from_slice(&text);
        f.extend_from_slice(&[0u8; 8]); // subsys
        f.extend_from_slice(&0x0100u16.to_le_bytes());
        f.extend_from_slice(b"IM");

        let vals = [1.5f64, -2.25, 3.0, 4.125];
        let name = b"X097_DE_time";
        // build miMATRIX body
        let mut body = Vec::new();
        body.extend_from_slice(&6u32.to_le_bytes()); // miUINT32 array flags
        body.extend_from_slice(&8u32.to_le_bytes());
        body.extend_from_slice(&6u32.to_le_bytes()); // mxDOUBLE
        body.extend_from_slice(&0u32.to_le_bytes());
        body.extend_from_slice(&5u32.to_le_bytes()); // miINT32 dims
        body.extend_from_slice(&8u32.to_le_bytes());
        body.extend_from_slice(&(vals.len() as i32).to_le_bytes());
        body.extend_from_slice(&1i32.to_le_bytes());
        body.extend_from_slice(&1u32.to_le_bytes()); // miINT8 name
        body.extend_from_slice(&(name.len() as u32).to_le_bytes());
        body.extend_from_slice(name);
        body.resize((body.len() + 7) / 8 * 8, 0); // pad
        body.extend_from_slice(&9u32.to_le_bytes()); // miDOUBLE data
        body.extend_from_slice(&((vals.len() * 8) as u32).to_le_bytes());
        for v in vals {
            body.extend_from_slice(&v.to_le_bytes());
        }
        f.extend_from_slice(&14u32.to_le_bytes()); // miMATRIX
        f.extend_from_slice(&(body.len() as u32).to_le_bytes());
        f.extend_from_slice(&body);

        let dir = std::env::temp_dir().join("bhr_mat_test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("fixture.mat");
        std::fs::write(&path, &f).unwrap();

        let got = read_cwru(&path, "DE_time").unwrap();
        assert_eq!(got, vals.to_vec());
    }

    #[test]
    fn npz_central_directory_is_where_the_eocd_says() {
        // Regression: the central-directory record was once 4 bytes long per
        // entry (external attrs written twice) and numpy refused the file.
        let dir = std::env::temp_dir().join("bhr_npz_test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.npz");
        write_npz(&path, &[("a", &[1.0, 2.0][..]), ("b", &[3.0][..])]).unwrap();
        let raw = std::fs::read(&path).unwrap();
        let eocd = raw.len() - 22;
        assert_eq!(&raw[eocd..eocd + 4], &0x06054b50u32.to_le_bytes(), "EOCD signature");
        let cd_size = u32::from_le_bytes(raw[eocd + 12..eocd + 16].try_into().unwrap()) as usize;
        let cd_off = u32::from_le_bytes(raw[eocd + 16..eocd + 20].try_into().unwrap()) as usize;
        assert_eq!(cd_off + cd_size, eocd, "central dir must end at the EOCD");
        assert_eq!(&raw[cd_off..cd_off + 4], &0x02014b50u32.to_le_bytes(), "central dir signature");
        // each central entry is 46 + name(5: "x.npy"); two entries here
        assert_eq!(cd_size, 2 * (46 + 5), "central entry size per spec");
        assert_eq!(&raw[cd_off + 46..cd_off + 51], b"a.npy");
    }

    #[test]
    fn npy_bytes_have_a_wellformed_header() {
        let b = npy_bytes_f64(&[1.0, 2.0, 3.0]);
        assert_eq!(&b[0..6], b"\x93NUMPY");
        let hlen = u16::from_le_bytes([b[8], b[9]]) as usize;
        assert_eq!((10 + hlen) % 64, 0, "header must 64-align");
        let header = std::str::from_utf8(&b[10..10 + hlen]).unwrap();
        assert!(header.contains("'<f8'") && header.contains("(3,)"));
        assert_eq!(b.len(), 10 + hlen + 24);
    }
}
