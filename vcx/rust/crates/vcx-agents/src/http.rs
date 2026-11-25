//! The one HTTP call Qwen needs: a JSON POST to Ollama over plain http, through a SOCKS5 proxy when one is set
//! (his PC's Ollama sits behind one), its answer read whole or line by line as it streams.

use std::io;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
const HEADER_LIMIT: usize = 64 * 1024;
const SOCKS_VERSION: u8 = 5;
const SOCKS_NO_AUTH: u8 = 0;
const SOCKS_CONNECT: u8 = 1;
const SOCKS_DOMAIN: u8 = 3;

pub struct Endpoint {
    pub host: String,
    pub port: u16,
    pub path: String,
}

/// `http://host[:port][/path]`; https would need TLS, which an Ollama on the tailnet does not use.
pub fn endpoint(url: &str) -> Result<Endpoint, String> {
    let lower = url.to_ascii_lowercase();
    let rest = if lower.starts_with("http://") { &url[7..] } else { return Err("Set an http:// Ollama URL in Settings.".into()) };
    let (authority, path) = rest.find('/').map_or((rest, "/"), |slash| (&rest[..slash], &rest[slash..]));
    let (host, port) = split_port(authority, 80).ok_or("Set a valid Ollama URL in Settings.")?;
    Ok(Endpoint { host, port, path: path.to_owned() })
}

/// `socks5://host:port` or `socks5h://host:port`, no credentials; both send the host name for the proxy to resolve.
pub fn proxy(text: &str) -> Result<Option<(String, u16)>, String> {
    if text.is_empty() {
        return Ok(None);
    }
    let invalid = || "Invalid Qwen proxy. Set /qwen proxy socks5://host:port or /qwen proxy none. No request was sent.".to_owned();
    let lower = text.to_ascii_lowercase();
    let rest = ["socks5://", "socks5h://"].iter().find(|scheme| lower.starts_with(*scheme)).map(|scheme| &text[scheme.len()..]).ok_or_else(invalid)?;
    let authority = rest.trim_end_matches('/');
    if authority.contains('@') || authority.contains('/') || !authority.contains(':') {
        return Err(invalid());
    }
    let (host, port) = split_port(authority, 0).filter(|(_, port)| *port > 0).ok_or_else(invalid)?;
    Ok(Some((host, port)))
}

fn split_port(authority: &str, default: u16) -> Option<(String, u16)> {
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) if !host.contains(']') || host.ends_with(']') => (host, port.parse().ok()?),
        _ => (authority, default),
    };
    let host = host.trim_start_matches('[').trim_end_matches(']');
    (!host.is_empty()).then(|| (host.to_owned(), port))
}

pub struct Response {
    pub status: u16,
    reader: BufReader<TcpStream>,
    chunked: bool,
    /// Bytes of the current chunk (chunked) or of the whole body (Content-Length) still to read.
    left: Option<u64>,
    done: bool,
    pending: Vec<u8>,
}

pub async fn post_json(endpoint: &Endpoint, via: Option<&(String, u16)>, body: &[u8]) -> io::Result<Response> {
    let mut stream = match via {
        Some((host, port)) => {
            let mut stream = connect(host, *port).await?;
            socks(&mut stream, &endpoint.host, endpoint.port).await?;
            stream
        }
        None => connect(&endpoint.host, endpoint.port).await?,
    };
    let host = if endpoint.port == 80 { endpoint.host.clone() } else { format!("{}:{}", endpoint.host, endpoint.port) };
    let head = format!("POST {} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nAccept: application/x-ndjson, application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", endpoint.path, body.len());
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(body).await?;
    stream.flush().await?;
    let mut reader = BufReader::new(stream);
    let (status, headers) = read_head(&mut reader).await?;
    let header = |name: &str| headers.iter().find(|(key, _)| key.eq_ignore_ascii_case(name)).map(|(_, value)| value.as_str());
    let chunked = header("transfer-encoding").is_some_and(|value| value.to_ascii_lowercase().contains("chunked"));
    let left = if chunked { Some(0) } else { header("content-length").and_then(|value| value.trim().parse().ok()) };
    Ok(Response { status, reader, chunked, left, done: false, pending: Vec::new() })
}

async fn connect(host: &str, port: u16) -> io::Result<TcpStream> {
    tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect((host, port))).await.map_err(|_| io::Error::new(io::ErrorKind::TimedOut, format!("{host}:{port} did not answer.")))?
}

async fn socks(stream: &mut TcpStream, host: &str, port: u16) -> io::Result<()> {
    let refused = |what: &str| io::Error::new(io::ErrorKind::ConnectionRefused, format!("The SOCKS proxy refused {what}."));
    stream.write_all(&[SOCKS_VERSION, 1, SOCKS_NO_AUTH]).await?;
    let mut answer = [0u8; 2];
    stream.read_exact(&mut answer).await?;
    if answer != [SOCKS_VERSION, SOCKS_NO_AUTH] {
        return Err(refused("a connection without credentials"));
    }
    let name = host.as_bytes();
    let length = u8::try_from(name.len()).map_err(|_| refused("a host name that long"))?;
    let mut request = vec![SOCKS_VERSION, SOCKS_CONNECT, 0, SOCKS_DOMAIN, length];
    request.extend_from_slice(name);
    request.extend_from_slice(&port.to_be_bytes());
    stream.write_all(&request).await?;
    let mut reply = [0u8; 4];
    stream.read_exact(&mut reply).await?;
    if reply[1] != 0 {
        return Err(refused(&format!("{host}:{port} (code {})", reply[1])));
    }
    let address = match reply[3] {
        1 => 4,
        4 => 16,
        _ => usize::from(stream.read_u8().await?),
    };
    let mut bound = vec![0u8; address + 2];
    stream.read_exact(&mut bound).await?;
    Ok(())
}

async fn read_head(reader: &mut BufReader<TcpStream>) -> io::Result<(u16, Vec<(String, String)>)> {
    let invalid = || io::Error::new(io::ErrorKind::InvalidData, "The server sent no HTTP answer.");
    let (mut total, mut status, mut headers) = (0, None, Vec::new());
    loop {
        let mut line = String::new();
        let read = reader.read_line(&mut line).await?;
        total += read;
        if read == 0 || total > HEADER_LIMIT {
            return Err(invalid());
        }
        let line = line.trim_end();
        if status.is_none() {
            status = line.split_whitespace().nth(1).and_then(|code| code.parse().ok());
            status.ok_or_else(invalid)?;
        } else if line.is_empty() {
            return Ok((status.unwrap_or_default(), headers));
        } else if let Some((key, value)) = line.split_once(':') {
            headers.push((key.trim().to_owned(), value.trim().to_owned()));
        }
    }
}

impl Response {
    /// The next bytes of the body, chunked encoding taken off; `None` at its end.
    async fn piece(&mut self) -> io::Result<Option<Vec<u8>>> {
        if self.done {
            return Ok(None);
        }
        if self.chunked && self.left == Some(0) {
            let mut size = String::new();
            let mut read = self.reader.read_line(&mut size).await?;
            if read > 0 && size.trim().is_empty() {
                size.clear();
                read = self.reader.read_line(&mut size).await?;
            }
            if read == 0 {
                self.done = true;
                return Ok(None);
            }
            let size = u64::from_str_radix(size.trim().split(';').next().unwrap_or_default(), 16).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "Bad chunk size."))?;
            if size == 0 {
                self.done = true;
                return Ok(None);
            }
            self.left = Some(size);
        }
        let mut buffer = vec![0u8; 16 * 1024];
        let want = self.left.map_or(buffer.len(), |left| buffer.len().min(left as usize));
        let read = self.reader.read(&mut buffer[..want]).await?;
        if read == 0 {
            self.done = true;
            // A body that ends before its length or its last chunk was cut; the caller tells it from a missing done event.
            return Ok(None);
        }
        buffer.truncate(read);
        if let Some(left) = self.left.as_mut() {
            *left -= read as u64;
            if *left == 0 && !self.chunked {
                self.done = true;
            }
        }
        Ok(Some(buffer))
    }

    pub async fn line(&mut self) -> io::Result<Option<String>> {
        loop {
            if let Some(end) = self.pending.iter().position(|byte| *byte == b'\n') {
                let line: Vec<u8> = self.pending.drain(..=end).collect();
                return Ok(Some(String::from_utf8_lossy(&line[..end]).into_owned()));
            }
            match self.piece().await? {
                Some(bytes) => self.pending.extend(bytes),
                None if self.pending.is_empty() => return Ok(None),
                None => return Ok(Some(String::from_utf8_lossy(&std::mem::take(&mut self.pending)).into_owned())),
            }
        }
    }

    pub async fn all(&mut self) -> io::Result<Vec<u8>> {
        let mut body = std::mem::take(&mut self.pending);
        while let Some(bytes) = self.piece().await? {
            body.extend(bytes);
        }
        Ok(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_an_ollama_url_and_a_socks_proxy() {
        let url = endpoint("http://100.100.151.8:11434/api/chat").unwrap();
        let bare = endpoint("http://localhost").unwrap();

        assert_eq!((url.host.as_str(), url.port, url.path.as_str()), ("100.100.151.8", 11434, "/api/chat"));
        assert_eq!((bare.port, bare.path.as_str()), (80, "/"));
        assert!(endpoint("https://host/api/chat").is_err());
        assert_eq!(proxy("socks5h://127.0.0.1:1056").unwrap(), Some(("127.0.0.1".into(), 1056)));
        assert_eq!(proxy("").unwrap(), None);
        assert!(proxy("socks5://user:pass@host:1").is_err());
        assert!(proxy("http://host:1").is_err());
    }
}
