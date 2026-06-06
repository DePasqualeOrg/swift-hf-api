// Copyright © Anthony DePasquale

// `FFIResult<T>` carries `HFErrorFFI`, which mirrors `hf_hub::HFError` for
// foreign-language consumers and is large by necessity (the variants embed
// `HttpErrorContextDTO` so Swift sees the full request context for HTTP
// failures). Boxing variants would change the UniFFI Error surface – the
// trade-off favors keeping callers ergonomic.
#![allow(clippy::result_large_err)]

mod core;

uniffi::setup_scaffolding!("hf_api_rust");
