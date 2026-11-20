import Dispatch
import Foundation
import StradaMAMMedia

// The ingest client's command line. All the work is in `IngestClient`; this file reads the
// arguments, keeps the process alive while watching, and stops cleanly on Control-C.

setvbuf(stdout, nil, _IOLBF, 0)  // whole lines at a time, so progress shows when output is piped

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data(("stradaxr-ingest: " + message + "\n").utf8))
    exit(status)
}

switch IngestClient.parse(Array(CommandLine.arguments.dropFirst())) {
case .help:
    print(IngestClient.usage)
    exit(0)

case .failure(let message):
    fail(message + "\nRun stradaxr-ingest --help for the options.", status: 2)

case .run(let options):
    if options.once {
        do {
            let summary = try await IngestClient.runOnce(options)
            print(IngestClient.describe(summary))
            exit(summary.exitStatus)
        } catch {
            fail(error.localizedDescription, status: 2)
        }
    }

    let session: IngestClient.Session
    do {
        session = try await IngestClient.startWatching(options)
    } catch {
        fail(error.localizedDescription, status: 2)
    }
    print("Watching \(options.folders.joined(separator: ", ")). Press Control-C to stop.")

    // Control-C or a termination request: finish writing state, report, and leave.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            Task {
                await session.engine.stop()
                let summary = await session.summary()
                print("\n" + IngestClient.describe(summary))
                exit(summary.exitStatus)
            }
        }
        source.resume()
        return source
    }
    // Wait for ever; the signal handlers end the process.
    while true {
        try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        withExtendedLifetime(signals) {}
    }
}
