fn main() {
    println!("cargo:rerun-if-changed=branding/gamenight.ico");
    #[cfg(windows)]
    {
        winres::WindowsResource::new()
            .set_icon("branding/gamenight.ico")
            .set("ProductName", "Splitscreen Club")
            .set("FileDescription", "Splitscreen Club")
            .set("InternalName", "GameNight")
            .set("CompanyName", "Ontola")
            .compile()
            .expect("compile Splitscreen Club Windows branding");
        // The launcher links the daemon library for local shelf loading. Cargo
        // carries its native branding resource; linking it twice duplicates VERSION.
    }
}
