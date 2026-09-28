use std::{env, fs, path::Path};

fn main() {
    let spec_path = "openapi.json";
    println!("cargo:rerun-if-changed={spec_path}");

    let file = fs::File::open(spec_path).expect("openapi.json missing at repo root");
    let mut spec: serde_json::Value = serde_json::from_reader(file).expect("invalid openapi.json");
    spec["paths"]["/api/v1/gardens/{garden}/latest-seed"]["get"]["responses"]
        .as_object_mut()
        .expect("latest-seed responses missing")
        .remove("204");
    let spec = serde_json::from_value(spec).expect("invalid codegen OpenAPI");

    let tokens = progenitor::Generator::default()
        .generate_tokens(&spec)
        .expect("progenitor codegen failed");
    let ast = syn::parse2(tokens).expect("parsing generated tokens failed");
    let content = prettyplease::unparse(&ast);

    let out_dir = env::var("OUT_DIR").expect("OUT_DIR unset");
    let out_file = Path::new(&out_dir).join("codegen.rs");
    fs::write(out_file, content).expect("writing codegen.rs failed");
}
