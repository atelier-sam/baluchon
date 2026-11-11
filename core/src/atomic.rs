//! Écriture atomique (tmp + rename), mode 600 sous unix.
//!
//! Utilisée pour tout fichier qu'un autre processus (Claude, un second wizard)
//! peut lire pendant qu'on écrit : un lecteur voit l'ancien contenu OU le
//! nouveau, jamais un fichier à moitié écrit.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

/// Compteur de processus : deux threads qui écrivent dans la même microseconde
/// (l'horloge macOS n'a pas de nanosecondes réelles) auraient le MÊME nom de
/// fichier temporaire et la création exclusive de l'un échouerait.
static SEQ: AtomicU64 = AtomicU64::new(0);

#[cfg(any(test, feature = "test-hooks"))]
thread_local! {
    /// Nombre de fsync de répertoire réussis par CE thread (preuve que l'appel a lieu).
    static DIR_SYNCS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// Lecture du compteur ci-dessus, pour les essais d'une autre crate (une édition étendue,
/// dont la place réservée fsync son répertoire par `sync_parent`).
///
/// WHY une fonctionnalité et pas `pub` tout court : le compteur n'a aucun usage hors
/// essais ; sans `test-hooks` il n'existe ni dans la bibliothèque ni dans le binaire.
#[cfg(any(test, feature = "test-hooks"))]
pub fn dir_syncs() -> usize {
    DIR_SYNCS.with(|c| c.get())
}

pub fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let tmp = dir.join(format!(
        ".{name}.ccp-tmp-{}-{nanos}-{seq}",
        std::process::id()
    ));
    let result = (|| {
        let mut opts = OpenOptions::new();
        opts.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut f = opts.open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        drop(f);
        rename_durable(&tmp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

/// `rename` dont le résultat survit à une coupure de courant.
///
/// WHY : `fsync` du FICHIER ne rend pas durable l'entrée de répertoire créée par
/// le `rename`. Après une coupure, le répertoire peut encore montrer l'ancien
/// contenu : pour le journal de renouvellement (`.ccp-pending`, seul dépositaire
/// des nouveaux jetons) c'est précisément le cas à éviter.
///
/// Si le `rename` a réussi mais que la durabilité n'a pas pu être confirmée
/// (vraie erreur d'E/S), l'erreur est renvoyée : le fichier EST en place, mais
/// l'appelant ne doit pas s'y fier comme à une écriture durable.
pub fn rename_durable(from: &Path, to: &Path) -> io::Result<()> {
    #[cfg(windows)]
    {
        windows_replace_write_through(from, to)
    }
    #[cfg(not(windows))]
    {
        fs::rename(from, to)?;
        sync_parent(to)
    }
}

/// fsync du répertoire qui contient `path` (Unix).
///
/// Les volumes qui ne savent pas le faire (exFAT/FAT d'une clé USB, certains
/// montages réseau : EINVAL, ENOTSUP…) sont tolérés : il n'y a rien de plus à
/// obtenir d'eux. Toute AUTRE erreur (EIO…) est remontée.
#[cfg(not(windows))]
pub fn sync_parent(path: &Path) -> io::Result<()> {
    let dir = path.parent().filter(|d| !d.as_os_str().is_empty());
    let dir = dir.unwrap_or_else(|| Path::new("."));
    let res = fs::File::open(dir).and_then(|d| d.sync_all());
    match res {
        Ok(()) => {
            #[cfg(any(test, feature = "test-hooks"))]
            DIR_SYNCS.with(|c| c.set(c.get() + 1));
            Ok(())
        }
        Err(e) if dir_sync_unsupported(&e) => Ok(()),
        Err(e) => Err(e),
    }
}

/// Cette erreur de fsync de répertoire veut-elle dire « ce volume ne sait pas » ?
#[cfg(not(windows))]
fn dir_sync_unsupported(e: &io::Error) -> bool {
    if matches!(
        e.kind(),
        io::ErrorKind::Unsupported | io::ErrorKind::InvalidInput
    ) {
        return true;
    }
    // std ne range pas ENOTSUP/EOPNOTSUPP sous `Unsupported` sur toutes les cibles.
    matches!(
        e.raw_os_error(),
        Some(c) if c == libc::ENODEV
            || c == libc::ENOTTY
            || c == libc::ENOSYS
            || c == libc::ENOTSUP
            || c == libc::EOPNOTSUPP
            || c == libc::EINVAL
    )
}

/// Windows : `MoveFileExW` avec `MOVEFILE_WRITE_THROUGH` ne rend la main qu'une
/// fois le déplacement écrit sur le disque. Si la source ou la destination est
/// tenue ouverte sans partage de suppression (lecteur concurrent, antivirus),
/// `MoveFileExW` refuse (5 ou 32) : on retombe alors sur `fs::rename`, dont le
/// renommage en sémantique POSIX passe, au prix de la seule garantie de durabilité.
#[cfg(windows)]
fn windows_replace_write_through(from: &Path, to: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };
    const ERROR_ACCESS_DENIED: i32 = 5;
    const ERROR_SHARING_VIOLATION: i32 = 32;
    let wide = |p: &Path| -> Vec<u16> { p.as_os_str().encode_wide().chain(Some(0)).collect() };
    let (f, t) = (wide(from), wide(to));
    // SAFETY : deux chaînes UTF-16 terminées par NUL, vivantes pendant l'appel.
    let ok = unsafe {
        MoveFileExW(
            f.as_ptr(),
            t.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if ok != 0 {
        return Ok(());
    }
    let err = io::Error::last_os_error();
    match err.raw_os_error() {
        Some(ERROR_ACCESS_DENIED) | Some(ERROR_SHARING_VIOLATION) => fs::rename(from, to),
        _ => Err(err),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replaces_content_and_leaves_no_tmp() {
        let t = tempfile::tempdir().unwrap();
        let p = t.path().join("a.json");
        write_atomic(&p, b"un").unwrap();
        write_atomic(&p, b"deux").unwrap();
        assert_eq!(fs::read(&p).unwrap(), b"deux");
        let n = fs::read_dir(t.path()).unwrap().count();
        assert_eq!(n, 1);
    }

    #[test]
    fn parallel_writers_never_collide_on_the_temporary_name() {
        let t = tempfile::tempdir().unwrap();
        let p = t.path().join("c.json");
        let hs: Vec<_> = (0..8)
            .map(|i| {
                let p = p.clone();
                std::thread::spawn(move || {
                    for _ in 0..50 {
                        write_atomic(&p, format!("{{\"w\":{i}}}").as_bytes()).unwrap();
                    }
                })
            })
            .collect();
        for h in hs {
            h.join().unwrap();
        }
        assert!(fs::read_to_string(&p).unwrap().starts_with("{\"w\":"));
        assert_eq!(
            fs::read_dir(t.path()).unwrap().count(),
            1,
            "aucun .ccp-tmp oublié"
        );
    }

    #[cfg(unix)]
    #[test]
    fn file_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let t = tempfile::tempdir().unwrap();
        let p = t.path().join("s");
        write_atomic(&p, b"x").unwrap();
        assert_eq!(
            fs::metadata(&p).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[cfg(not(windows))]
    #[test]
    fn the_parent_directory_is_fsynced_after_the_rename() {
        let t = tempfile::tempdir().unwrap();
        let p = t.path().join("j.json");
        let before = DIR_SYNCS.with(|c| c.get());
        write_atomic(&p, b"x").unwrap();
        assert_eq!(DIR_SYNCS.with(|c| c.get()), before + 1);
        // La moitié « place réservée » de cet essai a quitté ce module avec le code qu'elle teste.
    }

    #[cfg(not(windows))]
    #[test]
    fn a_volume_that_cannot_fsync_a_directory_is_tolerated_but_real_io_errors_are_not() {
        assert!(dir_sync_unsupported(&io::Error::from_raw_os_error(
            libc::ENOTSUP
        )));
        assert!(dir_sync_unsupported(&io::Error::from_raw_os_error(
            libc::EINVAL
        )));
        assert!(dir_sync_unsupported(&io::Error::from_raw_os_error(
            libc::ENODEV
        )));
        assert!(!dir_sync_unsupported(&io::Error::from_raw_os_error(
            libc::EIO
        )));
        assert!(!dir_sync_unsupported(&io::Error::from_raw_os_error(
            libc::ENOSPC
        )));
    }
}
