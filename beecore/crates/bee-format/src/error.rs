use std::fmt;

/// Error type for the `.bee` core. Kept dependency-free (no `thiserror`) so the
/// crate stays minimal for cross-compilation to mobile targets.
#[derive(Debug)]
pub enum Error {
    Io(std::io::Error),
    /// Malformed container / npy / npz structure.
    Format(String),
    /// Payload codec (flac / raw_zlib) failure.
    Codec(String),
    Json(serde_json::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Io(e) => write!(f, "io error: {e}"),
            Error::Format(m) => write!(f, "format error: {m}"),
            Error::Codec(m) => write!(f, "codec error: {m}"),
            Error::Json(e) => write!(f, "json error: {e}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::Json(e)
    }
}

pub type Result<T> = std::result::Result<T, Error>;
