mod wire_protocol;

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.iter().any(|a| a == "--version") {
        println!("{}", env!("CARGO_PKG_VERSION"));
        std::process::exit(0);
    }

    eprintln!("ct-shell-trace-writer: wire protocol parser not yet implemented");
    std::process::exit(1);
}
