//! Package classification by directory-name extension (explicit cases, so a wrong rule fails by name). Linux portable backend; not a statement about how
//! macOS Finder treats bundles.
use spacelyzer_engine::*;
use std::fs;

#[test]
fn only_directories_with_a_known_bundle_extension_are_packages_and_their_contents_still_count() {
    let d = std::env::temp_dir().join(format!("pkg-{}", std::process::id())); let _ = fs::remove_dir_all(&d); fs::create_dir_all(&d).unwrap();
    let d = d.canonicalize().unwrap();
    let pkgs = ["X.app", "Y.APP", "Z.Framework", "w.bundle", "v.plugin", "u.kext", "t.appex", "s.xpc", "r.photoslibrary", "has.dots.app"];
    let dirs = [".app", "app", "x.apps", "a.app.bak", "plain", "x.", "noext.appx"];
    for n in pkgs.iter().chain(dirs.iter()) { fs::create_dir_all(d.join(n)).unwrap(); fs::write(d.join(n).join("f"), vec![1u8; 5000]).unwrap(); }
    fs::write(d.join("file.app"), vec![1u8; 5000]).unwrap();
    let t = scan(&d, &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let kind = |name: &str| t.kind(t.find(d.join(name).to_str().unwrap()).unwrap_or_else(|| panic!("{name} missing")));
    for n in pkgs { assert_eq!(kind(n), Kind::Package, "{n}"); }
    for n in dirs { assert_eq!(kind(n), Kind::Directory, "{n}"); }
    assert_eq!(kind("file.app"), Kind::File, "a FILE named *.app is not a package");
    // Contents of a package are still scanned and counted: its size equals its child's.
    let p = t.find(d.join("X.app").to_str().unwrap()).unwrap();
    assert_eq!(t.children(p).len(), 1);
    assert_eq!(t.size(p), t.size(t.children(p).start));
    assert!(t.size(p) > 0);
}
