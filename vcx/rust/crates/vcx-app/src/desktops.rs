//! A window's desktop (macOS Space), kept across a restart as Swift `Desktops` keeps it: saved as its place among the
//! desktops, left to right and screen after screen, and given back once the reopened windows are all open. A desktop
//! that no longer exists leaves the window on the desktop in front.
//! Moving a window needs the bridged operation the Dock is handed: SLSMoveWindowsToManagedSpace moves nothing since
//! macOS 14.5 (Swift `Desktops.move`, Fleet's Spaces.swift).

use objc2::rc::Retained;
use objc2::runtime::{AnyClass, AnyObject, Sel};
use objc2::{ClassType, msg_send, sel};
use objc2_foundation::{NSArray, NSDictionary, NSNumber, NSString};
use std::ffi::{CStr, c_void};
use std::sync::OnceLock;

/// What `CGSCopySpacesForWindows` is asked for: current, other and user spaces (Swift's 0x7).
const ALL_SPACE_KINDS: i32 = 0x7;
/// A Space of type 0 is a desktop; a fullscreen one no window can join is left out.
const DESKTOP_TYPE: i64 = 0;
const SKYLIGHT: &CStr = c"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
const BRIDGED_PERFORM: &CStr = c"__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation";
const BRIDGED_MOVE: &CStr = c"SLSBridgedMoveWindowsToManagedSpaceOperation";

/// The window server's view of Spaces, behind a seam so the choice of a desktop is tested without a window.
pub trait Spaces {
    /// Every desktop's Space id, left to right, screen after screen.
    fn desktops(&self) -> Vec<u64>;
    /// The Spaces window `number` is on.
    fn of(&self, number: isize) -> Vec<u64>;
    fn move_window(&self, number: isize, space: u64);
}

/// The window's desktop as saved: its first Space's place among the desktops, none on a fullscreen Space.
pub fn index(spaces: &impl Spaces, number: isize) -> Option<usize> {
    if number <= 0 {
        return None;
    }
    let first = *spaces.of(number).first()?;
    spaces.desktops().iter().position(|&space| space == first)
}

/// Puts the window back on desktop `index`; one that no longer exists, or the window already there, moves nothing.
pub fn put_back(spaces: &impl Spaces, number: isize, index: usize) -> bool {
    if number <= 0 {
        return false;
    }
    let Some(&space) = spaces.desktops().get(index) else { return false };
    if spaces.of(number) == [space] {
        return false;
    }
    spaces.move_window(number, space);
    true
}

/// The desktops of `CGSCopyManagedDisplaySpaces`, given as each screen's Spaces with their type and id.
pub fn ordered(screens: &[Vec<(i64, u64)>]) -> Vec<u64> {
    screens.iter().flatten().filter(|(kind, _)| *kind == DESKTOP_TYPE).map(|&(_, id)| id).collect()
}

/// The window server of this Mac.
pub struct System;

impl Spaces for System {
    fn desktops(&self) -> Vec<u64> {
        let Some(api) = api() else { return Vec::new() };
        // SAFETY: a Copy function hands an owned array, or null.
        let Some(screens) = (unsafe { owned((api.managed_display_spaces)((api.connection)())) }) else { return Vec::new() };
        let integer = |space: &AnyObject, name: &str| value(space, &NSString::from_str(name)).and_then(|field| field.downcast::<NSNumber>().ok());
        let screens: Vec<Vec<(i64, u64)>> = items(&screens)
            .iter()
            .map(|screen| {
                let spaces = value(screen, &NSString::from_str("Spaces")).map(|spaces| items(&spaces)).unwrap_or_default();
                spaces.iter().filter_map(|space| Some((integer(space, "type")?.as_i64(), integer(space, "id64")?.as_u64()))).collect()
            })
            .collect();
        ordered(&screens)
    }

    fn of(&self, window: isize) -> Vec<u64> {
        let Some(api) = api() else { return Vec::new() };
        let windows = NSArray::from_retained_slice(&[NSNumber::new_isize(window)]);
        // SAFETY: the array lives across the call; a Copy function hands an owned array, or null.
        let Some(spaces) = (unsafe { owned((api.spaces_for_windows)((api.connection)(), ALL_SPACE_KINDS, Retained::as_ptr(&windows).cast())) }) else { return Vec::new() };
        items(&spaces).iter().filter_map(|space| space.downcast_ref::<NSNumber>()).map(NSNumber::as_u64).collect()
    }

    fn move_window(&self, window: isize, space: u64) {
        let Some(bridged) = bridged() else { return eprintln!("vcx-rust: this macOS has no bridged window move.") };
        let windows = NSArray::from_retained_slice(&[NSNumber::new_isize(window)]);
        // SAFETY: `init` is the class's own initWithWindows:spaceID: with that C signature, sent to a fresh alloc; the
        // operation is owned here and released after the perform function, which takes it unretained, has run.
        unsafe {
            let allocated: *mut AnyObject = msg_send![bridged.class, alloc];
            let operation = (bridged.init)(allocated, sel!(initWithWindows:spaceID:), Retained::as_ptr(&windows).cast(), space);
            if let Some(operation) = Retained::from_raw(operation) {
                (bridged.perform)(Retained::as_ptr(&operation) as *mut c_void);
            }
        }
    }
}

/// The window number tao's window has in the window server.
pub(crate) fn window_number(window: &tao::window::Window) -> isize {
    use objc2_app_kit::NSWindow;
    use tao::platform::macos::WindowExtMacOS;
    // SAFETY: tao hands the NSWindow it owns for as long as `window` lives, which outlasts this call.
    unsafe { (window.ns_window() as *const NSWindow).as_ref() }.map_or(0, NSWindow::windowNumber)
}

struct Api {
    connection: unsafe extern "C" fn() -> i32,
    managed_display_spaces: unsafe extern "C" fn(i32) -> *mut AnyObject,
    spaces_for_windows: unsafe extern "C" fn(i32, i32, *const c_void) -> *mut AnyObject,
}

fn api() -> Option<&'static Api> {
    static API: OnceLock<Option<Api>> = OnceLock::new();
    API.get_or_init(|| {
        let find = |name: &CStr| {
            // SAFETY: a lookup in the images AppKit loaded; null when absent.
            let address = unsafe { libc::dlsym(libc::RTLD_DEFAULT, name.as_ptr()) };
            (!address.is_null()).then_some(address)
        };
        // SAFETY: the private functions' C signatures, as Swift `Desktops` declares them.
        unsafe {
            Some(Api {
                connection: std::mem::transmute::<*mut c_void, unsafe extern "C" fn() -> i32>(find(c"CGSMainConnectionID")?),
                managed_display_spaces: std::mem::transmute::<*mut c_void, unsafe extern "C" fn(i32) -> *mut AnyObject>(find(c"CGSCopyManagedDisplaySpaces")?),
                spaces_for_windows: std::mem::transmute::<*mut c_void, unsafe extern "C" fn(i32, i32, *const c_void) -> *mut AnyObject>(find(c"CGSCopySpacesForWindows")?),
            })
        }
    })
    .as_ref()
}

type Initializer = unsafe extern "C" fn(*mut AnyObject, Sel, *const c_void, u64) -> *mut AnyObject;
type Perform = unsafe extern "C" fn(*mut c_void) -> i64;

struct Bridged {
    class: &'static AnyClass,
    init: Initializer,
    perform: Perform,
}

/// The bridged move this macOS needs, none when the class or its perform function is missing.
pub fn bridged_move_available() -> bool {
    bridged().is_some()
}

fn bridged() -> Option<&'static Bridged> {
    static BRIDGED: OnceLock<Option<Bridged>> = OnceLock::new();
    BRIDGED
        .get_or_init(|| {
            let class = AnyClass::get(BRIDGED_MOVE)?;
            let init = class.instance_method(sel!(initWithWindows:spaceID:))?.implementation();
            let perform = local_symbol(BRIDGED_PERFORM, SKYLIGHT)?;
            // SAFETY: the method's and the function's C signatures, as Swift `Desktops` calls them.
            Some(Bridged { class, init: unsafe { std::mem::transmute::<objc2::runtime::Imp, Initializer>(init) }, perform: unsafe { std::mem::transmute::<*mut c_void, Perform>(perform) } })
        })
        .as_ref()
}

#[repr(C)]
struct SymtabCommand {
    cmd: u32,
    cmdsize: u32,
    symoff: u32,
    nsyms: u32,
    stroff: u32,
    strsize: u32,
}

#[repr(C)]
struct Nlist64 {
    n_strx: u32,
    n_type: u8,
    n_sect: u8,
    n_desc: u16,
    n_value: u64,
}

#[repr(C)]
struct MachHeader64 {
    magic: u32,
    cputype: i32,
    cpusubtype: i32,
    filetype: u32,
    ncmds: u32,
    sizeofcmds: u32,
    flags: u32,
    reserved: u32,
}

#[repr(C)]
struct LoadCommand {
    cmd: u32,
    cmdsize: u32,
}

#[repr(C)]
struct SegmentCommand64 {
    cmd: u32,
    cmdsize: u32,
    segname: [u8; 16],
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    maxprot: i32,
    initprot: i32,
    nsects: u32,
    flags: u32,
}

const LC_SYMTAB: u32 = 0x2;
const LC_SEGMENT_64: u32 = 0x19;

unsafe extern "C" {
    fn _dyld_image_count() -> u32;
    fn _dyld_get_image_name(index: u32) -> *const libc::c_char;
    fn _dyld_get_image_header(index: u32) -> *const MachHeader64;
    fn _dyld_get_image_vmaddr_slide(index: u32) -> isize;
}

/// A local symbol, which dlsym cannot reach: read from the loaded image's symbol table (Swift `Desktops.symbol`).
fn local_symbol(name: &CStr, image: &CStr) -> Option<*mut c_void> {
    // SAFETY: dyld's own image list, read while the images stay loaded (system frameworks are never unloaded); the
    // load commands and the symbol table are walked within the sizes their headers give.
    unsafe {
        for index in 0.._dyld_image_count() {
            let path = _dyld_get_image_name(index);
            if path.is_null() || CStr::from_ptr(path) != image {
                continue;
            }
            let header = _dyld_get_image_header(index).as_ref()?;
            let slide = _dyld_get_image_vmaddr_slide(index);
            let mut command = (header as *const MachHeader64).cast::<u8>().add(size_of::<MachHeader64>());
            let (mut linkedit, mut symtab) = (None, None);
            for _ in 0..header.ncmds {
                let kind = command.cast::<LoadCommand>().read_unaligned();
                if kind.cmd == LC_SYMTAB {
                    symtab = Some(command.cast::<SymtabCommand>().read_unaligned());
                }
                if kind.cmd == LC_SEGMENT_64 {
                    let segment = command.cast::<SegmentCommand64>().read_unaligned();
                    if CStr::from_bytes_until_nul(&segment.segname).is_ok_and(|segment| segment == c"__LINKEDIT") {
                        linkedit = Some(segment);
                    }
                }
                command = command.add(kind.cmdsize as usize);
            }
            let (linkedit, symtab) = (linkedit?, symtab?);
            let base = linkedit.vmaddr as isize - linkedit.fileoff as isize + slide;
            let names = (base + symtab.stroff as isize) as *const libc::c_char;
            let entries = std::slice::from_raw_parts((base + symtab.symoff as isize) as *const Nlist64, symtab.nsyms as usize);
            return entries.iter().find(|entry| CStr::from_ptr(names.add(entry.n_strx as usize)) == name).map(|entry| (entry.n_value as isize + slide) as *mut c_void);
        }
        None
    }
}

/// SAFETY: `raw` is an owned (+1) object or null.
unsafe fn owned(raw: *mut AnyObject) -> Option<Retained<AnyObject>> {
    unsafe { Retained::from_raw(raw) }
}

fn is_kind<T: ClassType>(object: &AnyObject) -> bool {
    // SAFETY: isKindOfClass: takes any class and answers a BOOL.
    unsafe { msg_send![object, isKindOfClass: T::class()] }
}

fn items(list: &AnyObject) -> Vec<Retained<AnyObject>> {
    if !is_kind::<NSArray>(list) {
        return Vec::new();
    }
    // SAFETY: checked to be an array just above; its elements are objects.
    let list = unsafe { &*(list as *const AnyObject).cast::<NSArray<AnyObject>>() };
    list.to_vec()
}

fn value(dictionary: &AnyObject, key: &NSString) -> Option<Retained<AnyObject>> {
    if !is_kind::<NSDictionary>(dictionary) {
        return None;
    }
    // SAFETY: checked to be a dictionary just above; a key it lacks answers nil.
    unsafe { msg_send![dictionary, objectForKey: key] }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Desktops with their Space ids, and where each window stands.
    struct Fake {
        desktops: Vec<u64>,
        windows: RefCell<Vec<(isize, Vec<u64>)>>,
        moves: RefCell<Vec<(isize, u64)>>,
    }

    impl Fake {
        fn new(desktops: &[u64], windows: &[(isize, &[u64])]) -> Self {
            Fake { desktops: desktops.to_vec(), windows: RefCell::new(windows.iter().map(|(number, spaces)| (*number, spaces.to_vec())).collect()), moves: RefCell::default() }
        }
    }

    impl Spaces for Fake {
        fn desktops(&self) -> Vec<u64> {
            self.desktops.clone()
        }

        fn of(&self, number: isize) -> Vec<u64> {
            self.windows.borrow().iter().find(|(window, _)| *window == number).map(|(_, spaces)| spaces.clone()).unwrap_or_default()
        }

        fn move_window(&self, number: isize, space: u64) {
            self.moves.borrow_mut().push((number, space));
        }
    }

    #[test]
    fn saves_a_window_as_its_place_among_the_desktops() {
        let spaces = Fake::new(&[11, 22, 33], &[(7, &[33])]);

        let saved = index(&spaces, 7);

        assert_eq!(saved, Some(2));
    }

    #[test]
    fn saves_no_desktop_for_a_window_on_a_fullscreen_space_or_not_shown() {
        let spaces = Fake::new(&[11, 22], &[(7, &[99]), (8, &[])]);

        let saved = [index(&spaces, 7), index(&spaces, 8), index(&spaces, 0), index(&spaces, -1)];

        assert_eq!(saved, [None; 4]);
    }

    #[test]
    fn puts_a_reopened_window_back_on_its_desktop() {
        let spaces = Fake::new(&[11, 22, 33], &[(7, &[11])]);

        let moved = put_back(&spaces, 7, 1);

        assert!(moved);
        assert_eq!(*spaces.moves.borrow(), [(7, 22)]);
    }

    #[test]
    fn leaves_the_window_on_the_desktop_in_front_when_its_desktop_is_gone() {
        let spaces = Fake::new(&[11, 22], &[(7, &[11])]);

        let moved = put_back(&spaces, 7, 2);

        assert!(!moved);
        assert!(spaces.moves.borrow().is_empty());
    }

    #[test]
    fn moves_nothing_when_the_window_is_already_on_its_desktop() {
        let spaces = Fake::new(&[11, 22], &[(7, &[22])]);

        let moved = put_back(&spaces, 7, 1);

        assert!(!moved);
        assert!(spaces.moves.borrow().is_empty());
    }

    #[test]
    fn orders_desktops_left_to_right_screen_after_screen_without_fullscreen_spaces() {
        let screens = [vec![(0, 11), (4, 90), (0, 12)], vec![(0, 21)]];

        let desktops = ordered(&screens);

        assert_eq!(desktops, [11, 12, 21]);
    }

    #[test]
    fn finds_the_bridged_window_move_this_macos_needs() {
        let found = bridged_move_available();

        assert!(found, "SkyLight lost {BRIDGED_MOVE:?} or its perform function: windows can no longer be put back on their desktop");
    }

    /// Reads the window server of the Mac it runs on, so only by hand: `cargo test -p vcx-app -- --ignored`.
    #[test]
    #[ignore = "reads this Mac's desktops from its window server"]
    fn reads_every_desktop_of_this_mac_once() {
        let desktops = System.desktops();

        let mut distinct = desktops.clone();
        distinct.sort_unstable();
        distinct.dedup();
        eprintln!("desktops: {}", desktops.len());
        assert!(!desktops.is_empty());
        assert_eq!(distinct.len(), desktops.len());
    }
}
