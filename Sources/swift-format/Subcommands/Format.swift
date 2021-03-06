//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Foundation
import SwiftFormat
import SwiftFormatConfiguration
import SwiftSyntax
import TSCBasic

extension SwiftFormatCommand {
  /// Formats one or more files containing Swift code.
  struct Format: ParsableCommand {
    static var configuration = CommandConfiguration(
      abstract: "Format Swift source code",
      discussion: "When no files are specified, it expects the source from standard input.")

    /// Whether or not to format the Swift file in-place.
    ///
    /// If specified, the current file is overwritten when formatting.
    @Flag(
      name: .shortAndLong,
      help: "Overwrite the current file when formatting.")
    var inPlace: Bool

    @OptionGroup()
    var formatOptions: LintFormatOptions

    func validate() throws {
      if inPlace && formatOptions.paths.isEmpty {
        throw ValidationError("'--in-place' is only valid when formatting files")
      }
    }

    func run() throws {
      let diagnosticEngine = makeDiagnosticEngine()

      if formatOptions.paths.isEmpty {
        let configuration = try loadConfiguration(
          forSwiftFile: nil, configFilePath: formatOptions.configurationPath)
        formatMain(
          configuration: configuration, sourceFile: FileHandle.standardInput,
          assumingFilename: formatOptions.assumeFilename, inPlace: false,
          ignoreUnparsableFiles: formatOptions.ignoreUnparsableFiles,
          debugOptions: formatOptions.debugOptions, diagnosticEngine: diagnosticEngine)
      } else {
        try processSources(
          from: formatOptions.paths, configurationPath: formatOptions.configurationPath,
          diagnosticEngine: diagnosticEngine
        ) { sourceFile, path, configuration in
          formatMain(
            configuration: configuration, sourceFile: sourceFile, assumingFilename: path,
            inPlace: inPlace, ignoreUnparsableFiles: formatOptions.ignoreUnparsableFiles,
            debugOptions: formatOptions.debugOptions, diagnosticEngine: diagnosticEngine)
        }
      }

      try failIfDiagnosticsEmitted(diagnosticEngine)
    }
  }
}

/// Runs the formatting pipeline over the provided source file.
///
/// - Parameters:
///   - configuration: The `Configuration` that contains user-specific settings.
///   - sourceFile: A file handle from which to read the source code to be linted.
///   - assumingFilename: The filename of the source file, used in diagnostic output.
///   - inPlace: Whether or not to overwrite the current file when formatting.
///   - ignoreUnparsableFiles: Whether or not to ignore files that contain syntax errors.
///   - debugOptions: The set containing any debug options that were supplied on the command line.
///   - diagnosticEngine: A diagnostic collector that handles diagnostic messages.
/// - Returns: Zero if there were no format errors, otherwise a non-zero number.
private func formatMain(
  configuration: Configuration, sourceFile: FileHandle, assumingFilename: String?, inPlace: Bool,
  ignoreUnparsableFiles: Bool, debugOptions: DebugOptions, diagnosticEngine: DiagnosticEngine
) {
  // Even though `diagnosticEngine` is defined, it's use is reserved for fatal messages. Pass nil
  // to the formatter to suppress other messages since they will be fixed or can't be automatically
  // fixed anyway.
  let formatter = SwiftFormatter(configuration: configuration, diagnosticEngine: nil)
  formatter.debugOptions = debugOptions
  let assumingFileURL = URL(fileURLWithPath: assumingFilename ?? "<stdin>")

  guard let source = readSource(from: sourceFile) else {
    diagnosticEngine.diagnose(
      Diagnostic.Message(
        .error, "Unable to read source for formatting from \(assumingFileURL.path)."))
    return
  }

  do {
    if inPlace {
      let cwd = FileManager.default.currentDirectoryPath
      var buffer = BufferedOutputByteStream()
      try formatter.format(source: source, assumingFileURL: assumingFileURL, to: &buffer)
      buffer.flush()
      try localFileSystem.writeFileContents(
        AbsolutePath(assumingFileURL.path, relativeTo: AbsolutePath(cwd)),
        bytes: buffer.bytes
      )
    } else {
      try formatter.format(source: source, assumingFileURL: assumingFileURL, to: &stdoutStream)
      stdoutStream.flush()
    }
  } catch SwiftFormatError.fileNotReadable {
    let path = assumingFileURL.path
    diagnosticEngine.diagnose(
      Diagnostic.Message(
        .error, "Unable to format \(path): file is not readable or does not exist."))
    return
  } catch SwiftFormatError.fileContainsInvalidSyntax(let position) {
    guard !ignoreUnparsableFiles else {
      guard !inPlace else {
        // For in-place mode, nothing is expected to stdout and the file shouldn't be modified.
        return
      }
      stdoutStream.write(source)
      stdoutStream.flush()
      return
    }
    let path = assumingFileURL.path
    let location = SourceLocationConverter(file: path, source: source).location(for: position)
    diagnosticEngine.diagnose(
      Diagnostic.Message(.error, "file contains invalid or unrecognized Swift syntax."),
      location: location)
    return
  } catch {
    let path = assumingFileURL.path
    diagnosticEngine.diagnose(Diagnostic.Message(.error, "Unable to format \(path): \(error)"))
    return
  }
}
