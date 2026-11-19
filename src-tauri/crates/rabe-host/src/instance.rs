//! Data-directory isolation and the single-instance lock.
//!
//! One rule decides everything: the identifier white-listed in
//! [`crate::is_allowed_identifier`] alone determines the data directory
//! (`platform_data_dir()/<identifier>`) and the keyring service (`<identifier>`).
//! `COMAIL_DATA_DIR` and `COMAIL_KEYRING_SERVICE` are overwritten at start, not
//! read, so a stray `launchctl setenv`, a profiling shell or a spelling of the
//! identifier cannot point the host at the release app's database, at the
//! sandbox, or at a path reached through `..` or a symlink (audit N-H2a,
//! N-H2b, N-H2c, N-M5a).
//!
//! The order is fail-closed: create the directory, resolve it canonically,
//! check its identity against the release app, and only then take the lock and
//! let the core start. Anything that cannot be resolved is refused.

use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};

use crate::{HostConfig, HostError};

pub(crate) const DATA_DIR_ENV: &str = "COMAIL_DATA_DIR";
pub(crate) const KEYRING_ENV: &str = "COMAIL_KEYRING_SERVICE";
pub(crate) const RESOURCE_ENV: &str = "COMAIL_RESOURCE_DIR";

/// Keyring service [`HostConfig::for_tests`] runs with. No keychain entry of
/// this name exists; the test suites also set the core's credentials-file
/// switch, so nothing ever asks the login keychain.
pub(crate) const TEST_KEYRING_SERVICE: &str = "de.streil.rabe.native.test";

/// Keyring services that belong to the release app or to a pre-rename build.
///
/// Entry names are `"{account_id}:{slot}"` and every database starts numbering
/// accounts at 1, so writing under one of these services overwrites the daily
/// driver's credentials (password, OAuth refresh token, MCP token). The two
/// allowed identifiers can never produce one of these names; the check stays
/// as the invariant a future identifier must not break.
const RELEASE_KEYRING_SERVICES: &[&str] = &[
    // The core's own service - what the release app uses.
    "comail",
    // Release bundle identifier of the fork.
    "de.streil.rabe",
    // Upstream bundle identifier.
    "com.deanoss.comail",
    // The legacy service `credentials::adopt_legacy` reads from.
    "com.deanoss.comail.dev",
    // Dev build of the fork.
    "de.streil.rabe.dev",
];

/// Directory names that belong to the release app: its data directory (the
/// upstream name it kept) and its bundle identifier.
const RELEASE_DIR_NAMES: &[&str] = &["comail", "de.streil.rabe"];

/// Owns the locked data directory. Dropping it releases the `flock`.
pub(crate) struct Instance {
    pub data_dir: PathBuf,
    pub keyring_service: String,
    /// Held for the process lifetime; the `flock` goes away on close.
    _lock: File,
}

impl Instance {
    /// Validate, create, resolve, check and lock the data directory for `cfg`.
    ///
    /// The identifier and the keyring service are checked before the first
    /// disk operation; the directory is created before it is resolved, so a
    /// pre-existing symlink or a case variant is seen rather than skipped.
    pub(crate) fn acquire(cfg: &HostConfig) -> Result<Self, HostError> {
        let base = platform_data_dir()?;
        Self::acquire_in(cfg, &base)
    }

    /// [`Instance::acquire`] under an explicit platform data directory. Only
    /// the tests use this; no environment variable reaches either path.
    pub(crate) fn acquire_in(cfg: &HostConfig, base: &Path) -> Result<Self, HostError> {
        let data_dir = prepare_data_dir(cfg, base)?;
        let keyring_service = keyring_service_for(cfg)?.to_string();
        Self::finish(data_dir, keyring_service)
    }

    /// Lock a directory the caller has already verified (the sandbox seeder).
    /// No environment variable reaches this path, and no keyring is touched.
    pub(crate) fn lock_verified(
        data_dir: PathBuf,
        keyring_service: String,
    ) -> Result<Self, HostError> {
        Self::finish(data_dir, keyring_service)
    }

    fn finish(data_dir: PathBuf, keyring_service: String) -> Result<Self, HostError> {
        // `acquire_in` created and verified the directory already; the sandbox
        // seeder hands over a verified path that may not exist yet.
        std::fs::create_dir_all(&data_dir).map_err(|error| {
            HostError::new(
                "io",
                format!("cannot create {}: {error}", data_dir.display()),
            )
        })?;
        let lock = acquire_lock(&data_dir)?;
        Ok(Instance {
            data_dir,
            keyring_service,
            _lock: lock,
        })
    }

    /// Export the derived paths the core reads from the environment (`Paths`,
    /// `credentials::service`). They are set - overwritten, never appended -
    /// once, before the runtime and before any core thread exists; on the FFI
    /// path the surrounding AppKit process still has its own threads, which is
    /// the residual `set_var` hazard noted in the P1 audit (N1).
    ///
    /// # Safety
    ///
    /// Call before starting threads of our own; the caller guarantees no other
    /// thread of this process reads the environment concurrently.
    pub(crate) fn export_env(&self, resource_dir: Option<&Path>) {
        unsafe {
            std::env::set_var(DATA_DIR_ENV, &self.data_dir);
            std::env::set_var(KEYRING_ENV, &self.keyring_service);
            if let Some(dir) = resource_dir
                && std::env::var_os(RESOURCE_ENV).is_none()
            {
                std::env::set_var(RESOURCE_ENV, dir);
            }
        }
    }
}

pub(crate) fn platform_data_dir() -> Result<PathBuf, HostError> {
    comail_core::config::platform_data_dir()
        .ok_or_else(|| HostError::new("io", "no platform data directory for this user"))
}

/// Create and verify the instance directory. Returns its canonical path.
///
/// Fail-closed in this order (audit R3):
/// 1. the identifier must be one of the two exact ones,
/// 2. the leaf must not be a symlink (checked before anything is created),
/// 3. create the directory,
/// 4. resolve it; an unresolvable path is refused,
/// 5. a derived directory must still be a direct child under its own name,
/// 6. its identity must not be the release app's data directory.
fn prepare_data_dir(cfg: &HostConfig, base: &Path) -> Result<PathBuf, HostError> {
    if !crate::is_allowed_identifier(cfg.identifier()) {
        return Err(HostError::new(
            "refused",
            format!(
                "unknown identifier {:?}: only {} and {} are allowed",
                cfg.identifier(),
                crate::NATIVE_IDENTIFIER,
                crate::SANDBOX_IDENTIFIER
            ),
        ));
    }

    std::fs::create_dir_all(base).map_err(|error| {
        HostError::new("io", format!("cannot create {}: {error}", base.display()))
    })?;
    let base = base.canonicalize().map_err(|error| {
        HostError::new(
            "refused",
            format!("cannot resolve {}: {error}", base.display()),
        )
    })?;

    let derived = cfg.data_dir_override().is_none();
    let dir = match cfg.data_dir_override() {
        Some(dir) => dir.to_path_buf(),
        None => base.join(cfg.identifier()),
    };

    // A symlinked leaf is refused before it is followed: the lock, the
    // migrations and `--reset` must never act on a directory the identifier
    // does not name.
    if let Ok(metadata) = std::fs::symlink_metadata(&dir)
        && metadata.file_type().is_symlink()
    {
        return Err(HostError::new(
            "refused",
            format!("refusing symlinked data directory {}", dir.display()),
        ));
    }

    std::fs::create_dir_all(&dir).map_err(|error| {
        HostError::new("io", format!("cannot create {}: {error}", dir.display()))
    })?;
    let canonical = dir.canonicalize().map_err(|error| {
        HostError::new(
            "refused",
            format!("cannot resolve {}: {error}", dir.display()),
        )
    })?;

    if derived {
        let parent_ok = canonical.parent() == Some(base.as_path());
        let name_ok =
            canonical.file_name().and_then(|name| name.to_str()) == Some(cfg.identifier());
        if !parent_ok || !name_ok {
            return Err(HostError::new(
                "refused",
                format!(
                    "{} does not resolve to {}/{}",
                    dir.display(),
                    base.display(),
                    cfg.identifier()
                ),
            ));
        }
    }

    if is_release_dir_in(&canonical, &base) {
        return Err(HostError::new(
            "release_dir",
            format!(
                "refusing to open the release data directory {} ({} or {} under {})",
                canonical.display(),
                RELEASE_DIR_NAMES[0],
                RELEASE_DIR_NAMES[1],
                base.display()
            ),
        ));
    }
    Ok(canonical)
}

/// The keyring service for `cfg`: the identifier, or the test service for
/// [`HostConfig::for_tests`]. Never a release or legacy service.
pub(crate) fn keyring_service_for(cfg: &HostConfig) -> Result<&str, HostError> {
    let service = if cfg.data_dir_override().is_some() {
        TEST_KEYRING_SERVICE
    } else {
        cfg.identifier()
    };
    if is_release_keyring_service(service) {
        return Err(HostError::new(
            "refused",
            format!("refusing keyring service {service}: it belongs to the release or legacy app"),
        ));
    }
    Ok(service)
}

/// True when `dir` is the release data directory or anything inside it.
///
/// Fail-closed: an unresolvable path could be anything, including the release
/// directory through a spelling this check cannot see through, so it is
/// treated as the release directory (audit N-H2a: the old fail-open branch let
/// `x/../comail` through because neither the path nor its parent existed).
/// The identity check uses file identity (device + inode), so a case variant,
/// a symlink and a differently spelled path are recognised too.
pub(crate) fn is_release_dir_in(dir: &Path, base: &Path) -> bool {
    let (Ok(dir_canonical), Ok(base_canonical)) = (dir.canonicalize(), base.canonicalize()) else {
        return true;
    };

    // A directory directly under the platform data dir whose name is one of
    // the release names. This also catches a not-yet-created `Comail` on a
    // case-insensitive filesystem, where creating it would reuse `comail`.
    let in_base = dir_canonical.parent() == Some(base_canonical.as_path());
    let named_release = dir_canonical
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| {
            RELEASE_DIR_NAMES
                .iter()
                .any(|release| name.eq_ignore_ascii_case(release))
        });
    if in_base && named_release {
        return true;
    }

    for name in RELEASE_DIR_NAMES {
        let candidate = base_canonical.join(name);
        let candidate_canonical = candidate
            .canonicalize()
            .unwrap_or_else(|_| candidate.clone());
        if dir_canonical == candidate_canonical || dir_canonical.starts_with(&candidate_canonical) {
            return true;
        }
        // Same file even when the names differ (symlink, APFS case folding).
        if let (Ok(left), Ok(right)) = (dir.metadata(), candidate.metadata())
            && same_file(&left, &right)
        {
            return true;
        }
    }
    false
}

#[cfg(unix)]
fn same_file(left: &std::fs::Metadata, right: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    left.dev() == right.dev() && left.ino() == right.ino()
}

#[cfg(not(unix))]
fn same_file(_left: &std::fs::Metadata, _right: &std::fs::Metadata) -> bool {
    false
}

/// True when `service` is (or is built from) a release/legacy keyring service.
///
/// Exact matches cover the five known services. The dotted-component check
/// covers a suffixed service such as `comail.profiling`: it is a different
/// keychain entry, but it belongs to the release family and refusing it costs
/// the user only a different name. `de.streil.rabe.native` stays allowed - it
/// shares a prefix with the release identifier but no component.
pub(crate) fn is_release_keyring_service(service: &str) -> bool {
    let normalized = service.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        return false;
    }
    let components: Vec<&str> = normalized
        .split(['.', ':', '/'])
        .filter(|component| !component.is_empty())
        .collect();
    RELEASE_KEYRING_SERVICES.iter().any(|release| {
        normalized == *release || components.iter().any(|component| component == release)
    })
}

/// `flock(LOCK_EX | LOCK_NB)` on `<data_dir>/instance.lock`.
fn acquire_lock(data_dir: &Path) -> Result<File, HostError> {
    let path = data_dir.join("instance.lock");
    let mut options = OpenOptions::new();
    options.create(true).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options.open(&path).map_err(|error| {
        HostError::new("io", format!("cannot open {}: {error}", path.display()))
    })?;

    #[cfg(unix)]
    {
        use std::os::unix::io::AsRawFd;
        // SAFETY: the descriptor stays open for the lifetime of `file`.
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc != 0 {
            let error = std::io::Error::last_os_error();
            let busy = matches!(
                error.raw_os_error(),
                Some(code) if code == libc::EWOULDBLOCK || code == libc::EAGAIN
            );
            return Err(if busy {
                HostError::new(
                    "instance_locked",
                    format!("another instance holds {}", path.display()),
                )
            } else {
                HostError::new("io", format!("cannot lock {}: {error}", path.display()))
            });
        }
    }

    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::HostConfig;

    #[test]
    fn release_keyring_services_are_refused() {
        for service in [
            "comail",
            "Comail",
            " de.streil.rabe ",
            "com.deanoss.comail",
            "com.deanoss.comail.dev",
            "de.streil.rabe.dev",
            "comail.profiling",
            "profile.comail",
        ] {
            assert!(
                is_release_keyring_service(service),
                "{service:?} must be refused"
            );
        }
        for service in [
            "de.streil.rabe.native",
            "de.streil.rabe.native.sandbox",
            TEST_KEYRING_SERVICE,
            "comail-native",
            "",
        ] {
            assert!(
                !is_release_keyring_service(service),
                "{service:?} must stay allowed"
            );
        }
    }

    #[test]
    fn the_keyring_service_is_the_identifier() {
        let native = HostConfig::default();
        assert_eq!(
            keyring_service_for(&native).expect("native"),
            "de.streil.rabe.native"
        );
        let sandbox = HostConfig::new(crate::SANDBOX_IDENTIFIER).expect("sandbox");
        assert_eq!(
            keyring_service_for(&sandbox).expect("sandbox"),
            "de.streil.rabe.native.sandbox"
        );
        let dir = tempfile::tempdir().expect("dir");
        let tests = HostConfig::for_tests(dir.path());
        assert_eq!(
            keyring_service_for(&tests).expect("tests"),
            TEST_KEYRING_SERVICE
        );
    }

    #[test]
    fn the_data_dir_follows_only_the_identifier() {
        let base = tempfile::tempdir().expect("base");
        let canonical_base = base.path().canonicalize().expect("canonical base");

        // Nothing in the resolution path reads `COMAIL_DATA_DIR` or
        // `COMAIL_KEYRING_SERVICE`; the identifier alone decides both (audit
        // R2). `export_env` writes the derived values afterwards.
        let native = Instance::acquire_in(&HostConfig::default(), base.path()).expect("native");
        assert_eq!(
            native.data_dir,
            canonical_base.join(crate::NATIVE_IDENTIFIER)
        );
        assert_eq!(native.keyring_service, crate::NATIVE_IDENTIFIER);

        let sandbox = Instance::acquire_in(
            &HostConfig::new(crate::SANDBOX_IDENTIFIER).expect("config"),
            base.path(),
        )
        .expect("sandbox");
        assert_eq!(
            sandbox.data_dir,
            canonical_base.join(crate::SANDBOX_IDENTIFIER)
        );
        assert_eq!(sandbox.keyring_service, crate::SANDBOX_IDENTIFIER);

        // The test constructor moves only the directory, never the identifier.
        let foreign = tempfile::tempdir().expect("foreign dir");
        let tests = Instance::acquire_in(&HostConfig::for_tests(foreign.path()), base.path())
            .expect("test instance");
        assert_eq!(
            tests.data_dir,
            foreign.path().canonicalize().expect("canonical foreign")
        );
        assert_eq!(tests.keyring_service, TEST_KEYRING_SERVICE);
    }

    #[test]
    fn the_release_directory_is_recognised_by_identity() {
        let base = tempfile::tempdir().expect("base");
        let release = base.path().join("comail");
        std::fs::create_dir(&release).expect("release dir");

        // The literal name, a case variant (APFS folds case) and a symlink.
        assert!(is_release_dir_in(&release, base.path()));
        assert!(is_release_dir_in(&base.path().join("Comail"), base.path()));
        let link = base.path().join("elsewhere");
        std::os::unix::fs::symlink(&release, &link).expect("symlink");
        assert!(is_release_dir_in(&link, base.path()));

        // A subdirectory, and the fork's release identifier.
        let sub = release.join("attachments");
        std::fs::create_dir(&sub).expect("subdir");
        assert!(is_release_dir_in(&sub, base.path()));
        let fork = base.path().join("de.streil.rabe");
        std::fs::create_dir(&fork).expect("fork release dir");
        assert!(is_release_dir_in(&fork, base.path()));

        // An unresolvable path is refused instead of let through (N-H2a).
        assert!(is_release_dir_in(
            &base.path().join("x/../comail"),
            base.path()
        ));

        // The paths the native instance actually uses stay allowed.
        for name in [
            crate::NATIVE_IDENTIFIER,
            crate::SANDBOX_IDENTIFIER,
            "comail-backup",
            "somewhere-else",
        ] {
            let dir = base.path().join(name);
            std::fs::create_dir(&dir).expect("allowed dir");
            assert!(
                !is_release_dir_in(&dir, base.path()),
                "{name} must stay allowed"
            );
        }
    }

    #[test]
    fn a_symlinked_instance_directory_is_refused() {
        let base = tempfile::tempdir().expect("base");
        let release = base.path().join("comail");
        std::fs::create_dir(&release).expect("release dir");
        std::os::unix::fs::symlink(&release, base.path().join(crate::NATIVE_IDENTIFIER))
            .expect("symlink");

        let error = match Instance::acquire_in(&HostConfig::default(), base.path()) {
            Ok(_) => panic!("a symlinked instance dir must be refused"),
            Err(error) => error,
        };
        assert_eq!(error.code, "refused", "{error}");
    }
}
