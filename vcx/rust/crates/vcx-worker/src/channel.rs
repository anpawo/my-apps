//! The worker's side of the socket, as the Swift `RuntimeListener` and `RuntimeChannel` hold it: a private folder, a
//! lock so one worker serves a path, and per frontend a bounded outgoing queue.

use std::cell::{Cell, RefCell};
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::rc::{Rc, Weak};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::net::unix::OwnedWriteHalf;
use tokio::sync::mpsc;
use vcx_proto::Object;
use vcx_proto::frame::{self, FrameDecoder};

pub const MAX_BUFFERED_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_QUEUED_FRAMES: usize = 1024;
const PRIVATE_FOLDER: u32 = 0o700;
const PRIVATE_SOCKET: u32 = 0o600;
const SOCKET_UMASK: libc::mode_t = 0o177;
const READ_CHUNK: usize = 64 * 1024;

fn refuse(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}

/// Lock files beside the socket; the worker removes them when it exits.
pub fn lock_files(socket: &Path) -> [PathBuf; 2] {
    [".lock", ".launch.lock"].map(|suffix| PathBuf::from(format!("{}{suffix}", socket.display())))
}

pub struct Listener {
    pub listener: tokio::net::UnixListener,
    _lock: File,
    pub path: PathBuf,
}

/// Binds the socket once this worker holds its lock. A socket left by a dead worker is replaced.
pub fn listen(path: &Path) -> io::Result<Listener> {
    let user = unsafe { libc::geteuid() };
    let parent = path.parent().ok_or_else(|| refuse("Runtime socket has no parent directory."))?;
    let folder = fs::symlink_metadata(parent)?;
    if !folder.is_dir() || folder.uid() != user || folder.mode() & 0o777 != PRIVATE_FOLDER {
        return Err(refuse("Runtime directory must be private and owned by this user."));
    }
    let [lock_path, _] = lock_files(path);
    let lock = OpenOptions::new().read(true).write(true).create(true).mode(PRIVATE_SOCKET).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(&lock_path)?;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(io::Error::new(io::ErrorKind::AddrInUse, "Another runtime worker serves this socket."));
    }
    match fs::symlink_metadata(path) {
        Ok(existing) if existing.file_type().is_socket() && existing.uid() == user => fs::remove_file(path)?,
        Ok(_) => return Err(refuse("The runtime socket path is taken by something else.")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    // Created private through the umask: a chmod after bind leaves a moment in which a client finds the socket open
    // to others and refuses it.
    let previous = unsafe { libc::umask(SOCKET_UMASK) };
    let bound = std::os::unix::net::UnixListener::bind(path);
    unsafe { libc::umask(previous) };
    let listener = bound?;
    listener.set_nonblocking(true)?;
    Ok(Listener { listener: tokio::net::UnixListener::from_std(listener)?, _lock: lock, path: path.to_owned() })
}

pub fn peer_user(stream: &UnixStream) -> io::Result<libc::uid_t> {
    let (mut user, mut group) = (0, 0);
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut user, &mut group) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(user)
}

/// One frontend connection. Sending never waits: a frontend that stops reading is closed once its queue is full.
pub struct Channel {
    pub id: u64,
    queue: RefCell<Option<mpsc::Sender<Vec<u8>>>>,
    queued_bytes: Cell<usize>,
    closed: Cell<bool>,
    fd: RawFd,
}

impl Channel {
    pub fn send(&self, message: &Object) -> Result<(), ()> {
        if self.closed.get() {
            return Err(());
        }
        let data = frame::encode(message).map_err(|_| ())?;
        let length = data.len();
        if self.queued_bytes.get() + length > MAX_BUFFERED_BYTES {
            self.close();
            return Err(());
        }
        let sent = self.queue.borrow().as_ref().is_some_and(|queue| queue.try_send(data).is_ok());
        if !sent {
            self.close();
            return Err(());
        }
        self.queued_bytes.set(self.queued_bytes.get() + length);
        Ok(())
    }

    pub fn is_closed(&self) -> bool {
        self.closed.get()
    }

    /// Shuts the socket both ways; the reader then sees its end and tells the server once.
    pub fn close(&self) {
        if self.closed.replace(true) {
            return;
        }
        self.queue.borrow_mut().take();
        unsafe { libc::shutdown(self.fd, libc::SHUT_RDWR) };
    }
}

/// Starts reading and writing `stream`. `on_message` gets each frame; `on_close` runs once, when the reader ends.
pub fn start(stream: UnixStream, id: u64, on_message: impl Fn(&Rc<Channel>, Object) + 'static, on_close: impl FnOnce(&Rc<Channel>) + 'static) -> Rc<Channel> {
    let fd = stream.as_raw_fd();
    let (mut reader, writer) = stream.into_split();
    let (queue, frames) = mpsc::channel(MAX_QUEUED_FRAMES);
    let channel = Rc::new(Channel { id, queue: RefCell::new(Some(queue)), queued_bytes: Cell::new(0), closed: Cell::new(false), fd });
    tokio::task::spawn_local(write(writer, frames, Rc::downgrade(&channel)));
    let reading = Rc::clone(&channel);
    tokio::task::spawn_local(async move {
        let mut decoder = FrameDecoder::default();
        let mut buffer = vec![0; READ_CHUNK];
        'read: while !reading.is_closed() {
            let count = match reader.read(&mut buffer).await {
                Ok(0) | Err(_) => break,
                Ok(count) => count,
            };
            // A frame over the limit or not JSON ends the connection, as the Swift channel does.
            let Ok(messages) = decoder.push(&buffer[..count]) else { break };
            for message in messages {
                if reading.is_closed() {
                    break 'read;
                }
                on_message(&reading, message);
            }
        }
        reading.closed.set(true);
        reading.queue.borrow_mut().take();
        on_close(&reading);
        drop(reader);
    });
    channel
}

async fn write(mut writer: OwnedWriteHalf, mut frames: mpsc::Receiver<Vec<u8>>, channel: Weak<Channel>) {
    while let Some(data) = frames.recv().await {
        let failed = writer.write_all(&data).await.is_err();
        let Some(channel) = channel.upgrade() else { return };
        channel.queued_bytes.set(channel.queued_bytes.get().saturating_sub(data.len()));
        if failed {
            channel.close();
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn binds_the_socket_private_whatever_the_umask_and_restores_it() {
        let folder = std::env::temp_dir().join(format!("vcx-worker-listen-{}", std::process::id()));
        let _ = fs::remove_dir_all(&folder);
        fs::create_dir(&folder).unwrap();
        fs::set_permissions(&folder, fs::Permissions::from_mode(PRIVATE_FOLDER)).unwrap();
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let open = 0;
        let before = unsafe { libc::umask(open) };

        let listener = runtime.block_on(async { listen(&folder.join("w.sock")) }).unwrap();
        let after = unsafe { libc::umask(before) };

        assert_eq!(fs::metadata(&listener.path).unwrap().mode() & 0o777, PRIVATE_SOCKET);
        assert_eq!(after, open, "the process umask is given back");
        drop(listener);
        fs::remove_dir_all(folder).unwrap();
    }
}
