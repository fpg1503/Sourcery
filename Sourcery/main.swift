//
//  main.swift
//  Sourcery
//
//  Created by Krzysztof Zablocki on 09/12/2016.
//  Copyright © 2016 Pixle. All rights reserved.
//

import Foundation
import Commander
import PathKit
import Yams
import XcodeEdit
import SourceryRuntime

extension Path: ArgumentConvertible {
    /// :nodoc:
    public init(parser: ArgumentParser) throws {
        if let path = parser.shift() {
            self.init(path)
        } else {
            throw ArgumentError.missingValue(argument: nil)
        }
    }
}

struct CustomArguments: ArgumentConvertible {
    let arguments: Annotations

    init(parser: ArgumentParser) throws {
        guard let args = try parser.shiftValueForOption("args") else {
            self.arguments = Annotations()
            return
        }

        self.arguments = AnnotationsParser.parse(line: args)
    }

    init(arguments: [String: NSObject] = [:]) {
        self.arguments = arguments
    }

    var description: String {
        return arguments.description
    }

}

fileprivate enum Validators {
    static func isReadable(path: Path) -> Path {
        if !path.isReadable {
            Log.error("'\(path)' does not exist or is not readable.")
            exit(1)
        }

        return path
    }

    static func isFileOrDirectory(path: Path) -> Path {
        _ = isReadable(path: path)

        if !(path.isDirectory || path.isFile) {
            Log.error("'\(path)' isn't a directory or proper file.")
            exit(2)
        }

        return path
    }

    static func isWritable(path: Path, autoLock: Bool) -> Path {
        let pathExistsAndIsNotWritable = path.exists && !path.isWritable
        let pathExistsAndWillNotBeWritableIfUnlocked: Bool = {
            guard path.exists, autoLock, path.isImmutable else {
                return false
            }

            do {
                try path.setImmutable(false)
                let isWritableIfUnlocked = path.isWritable
                try path.setImmutable(true)

                return !isWritableIfUnlocked
            } catch {
                Log.error("Checking if '\(path)' is writable failed.")

                return false
            }
        }()
        
        if pathExistsAndIsNotWritable &&
           pathExistsAndWillNotBeWritableIfUnlocked {
            Log.error("'\(path)' isn't writeable.")
            exit(2)
        }
        return path
    }
}

extension Configuration {

    func validate() {
        guard !source.isEmpty else {
            Log.error("No sources provided.")
            exit(3)
        }
        if case let .sources(sources) = source {
            _ = sources.allPaths.map(Validators.isReadable(path:))
        }
        _ = templates.allPaths.map(Validators.isReadable(path:))
        guard !templates.isEmpty else {
            Log.error("No templates provided.")
            exit(3)
        }
        _ = Validators.isWritable(path: output, autoLock: autoLock)
    }

}

func runCLI() {
    command(
        Flag("watch",
             flag: "w",
             description: "Watch template for changes and regenerate as needed."),
        Flag("disableCache",
             description: "Stops using cache."),
        Flag("verbose",
             flag: "v",
             description: "Turn on verbose logging"),
        Flag("quiet",
             flag: "q",
             description: "Turn off any logging, only emmit errors"),
        Flag("prune",
             flag: "p",
             description: "Remove empty generated files"),
        Flag("autoLock",
             description: "Automatically locks all the output files"),
        VariadicOption<Path>("sources", description: "Path to a source swift files"),
        VariadicOption<Path>("templates", description: "Path to templates. File or Directory."),
        Option<Path>("output", ".", description: "Path to output. File or Directory. Default is current path."),
        Option<Path>("config", ".", description: "Path to config file. Directory. Default is current path."),
        Argument<CustomArguments>("args", description: "Custom values to pass to templates.")
    ) { watcherEnabled, disableCache, verboseLogging, quiet, prune, autoLock, sources, templates, output, configPath, args in
        do {
            Log.level = verboseLogging ? .verbose : quiet ? .errors : .warnings
            let configuration: Configuration

            let yamlPath: Path = configPath + ".sourcery.yml"
            if yamlPath.exists, let dict = try Yams.load(yaml: yamlPath.read()) as? [String: Any] {
                configuration = Configuration(dict: dict, relativePath: configPath, autoLock: autoLock)
            } else {
                configuration = Configuration(sources: sources,
                                              templates: templates,
                                              output: output,
                                              args: args.arguments,
                                              autoLock: autoLock)
            }

            configuration.validate()

            let start = CFAbsoluteTimeGetCurrent()
            let sourcery = Sourcery(verbose: verboseLogging,
                                    watcherEnabled: watcherEnabled,
                                    cacheDisabled: disableCache,
                                    prune: prune,
                                    autoLock: autoLock,
                                    arguments: configuration.args)
            if let keepAlive = try sourcery.processFiles(
                configuration.source,
                usingTemplates: configuration.templates,
                output: configuration.output) {
                RunLoop.current.run()
                _ = keepAlive
            } else {
                Log.info("Processing time \(CFAbsoluteTimeGetCurrent() - start) seconds")
            }
        } catch {
            Log.error("\(error)")
            exit(4)
        }
        }.run(Sourcery.version)
}

var inUnitTests = NSClassFromString("XCTest") != nil

#if os(macOS)
import AppKit

if !inUnitTests {
    runCLI()
} else {
    //! Need to run something for tests to work
    final class TestApplicationController: NSObject, NSApplicationDelegate {
        let window =   NSWindow()

        func applicationDidFinishLaunching(aNotification: NSNotification) {
            window.setFrame(CGRect(x: 0, y: 0, width: 0, height: 0), display: false)
            window.makeKeyAndOrderFront(self)
        }

        func applicationWillTerminate(aNotification: NSNotification) {
        }

    }

    autoreleasepool { () -> Void in
        let app =   NSApplication.shared()
        let controller =   TestApplicationController()

        app.delegate   = controller
        app.run()
    }
}
#endif
