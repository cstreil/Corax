//! `uniffi-bindgen` in library mode: reads the metadata embedded in
//! `libcorax_uniffi.a` and writes Swift bindings.
//!
//! ```text
//! uniffi-bindgen generate --library target/release/libcorax_uniffi.a \
//!     --language swift --out-dir out --no-format
//! ```

fn main() {
    uniffi::uniffi_bindgen_main()
}
