#!/usr/bin/env python3
"""Compile the whole ReaderContent with explicit transport/model leaves.

Linux supplies minimal publication interfaces; macOS uses system SwiftUI/Combine.
No resolver storage, Realm, source loading or WebKit framework runs in this graph.
The native-intended XCTest file calls the public entry through a portable loader.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]

def identity(path):
    b=path.read_bytes()
    return dict(bytes=len(b), sha256=hashlib.sha256(b).hexdigest(),
                git_blob=hashlib.sha1(f'blob {len(b)}\0'.encode()+b).hexdigest())

def command(argv, directory, output, label, timeout=120):
    """Retain logs and join the command, including timeout cleanup.

    SwiftPM may put XCTest in a separate process group. Capture attached
    descendants before killing the parent so that child cannot keep running.
    This supervises our test command, not arbitrary detached daemon processes.
    """
    with (output/f'{label}.out').open('wb') as out, (output/f'{label}.err').open('wb') as err:
        process = subprocess.Popen(argv, cwd=directory, stdout=out, stderr=err,
                                   start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except BaseException:
            descendants = {process.pid}
            try:
                table = subprocess.run(['ps', '-e', '-o', 'pid=', '-o', 'ppid='],
                                       capture_output=True, text=True, check=True, timeout=3)
                rows = [tuple(map(int, line.split())) for line in table.stdout.splitlines()]
                while True:
                    children = {pid for pid, parent in rows if parent in descendants} - descendants
                    if not children:
                        break
                    descendants.update(children)
            finally:
                for pid in descendants - {process.pid}:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            raise

def verify(lines, status, expected):
    rows=[]
    for line in lines:
        rows+=re.findall(r"Test Case '[^'\n]*ReaderContentLoadingOwnershipTests[. ](test\w+)\]?' (passed|failed|skipped)",line)
    if not expected or len(expected)!=len(set(expected)):
        raise ValueError('Invalid expected method roster')
    if sorted(name for name,_ in rows)!=sorted(expected) or any(v=='skipped' for _,v in rows):
        raise ValueError('Missing, duplicate, unexpected or skipped test receipt')
    failed=sum(v=='failed' for _,v in rows)
    if status != (1 if failed else 0): raise ValueError('Contradictory process status')
    return dict(total=len(rows),passed=len(rows)-failed,failed=failed,methods=dict(rows))

def main():
    a=argparse.ArgumentParser(description=__doc__)
    a.add_argument('--source',type=Path,default=ROOT/'Sources/LakeOfFireContent/Reader/ReaderContent.swift')
    a.add_argument('--tests',type=Path,default=ROOT/'Tests/LakeOfFireTests/ReaderContentLoadingOwnershipTests.swift')
    a.add_argument('--output',type=Path,required=True)
    a.add_argument('--optimized',action='store_true')
    a.add_argument('--direct-resolver',action='store_true',help='Run the same native-intended per-call resolver entry')
    a.add_argument('--allow-warnings',action='store_true',help='For original source with existing unused diagnostic variables')
    a.add_argument('--thread-sanitizer',action='store_true')
    args=a.parse_args()
    args.output.mkdir(parents=True,exist_ok=False)
    output=args.output.resolve(); pkg=output/'package'
    report=dict(complete=False,passed=False,inputs={},commands=[],configuration='release' if args.optimized else 'debug',
                scope='Complete ReaderContent; controlled resolver/model and platform interfaces; no Realm/WebKit/app',
                direct_resolver=args.direct_resolver, warnings_as_errors=not args.allow_warnings,
                thread_sanitizer=args.thread_sanitizer, native_combine=sys.platform=='darwin')
    try:
        for name in ['LakeOfFireContent','LakeOfFireCore','SwiftUIWebView']:
            (pkg/'Sources'/name).mkdir(parents=True)
        (pkg/'Tests/ContentTests').mkdir(parents=True)
        (pkg/'Sources/LakeOfFireContent/ReaderContent.swift').write_bytes(args.source.read_bytes())
        (pkg/'Sources/LakeOfFireContent/Collaborators.swift').write_bytes((HERE/'Collaborators.swift').read_bytes())
        (pkg/'Tests/ContentTests/Tests.swift').write_bytes(args.tests.read_bytes())
        (pkg/'Sources/LakeOfFireCore/Interface.swift').write_text('@_exported import Foundation\n@_exported import CoreFoundation\n')
        (pkg/'Sources/SwiftUIWebView/Interface.swift').write_text('''@MainActor public final class WebViewReaderLoadActivity {
 public static let shared = WebViewReaderLoadActivity()
 public var hasPendingPreProvisionalLoad = false
}
''')
        dependencies=''; extra=''
        if sys.platform.startswith('linux'):
            for name in ['SwiftUI','Combine']: (pkg/'Sources'/name).mkdir()
            (pkg/'Sources/SwiftUI/Interface.swift').write_text('@_exported import Foundation\n@_exported import CoreFoundation\n@_exported import Combine\n')
            (pkg/'Sources/Combine/Interface.swift').write_text('''import Foundation
@MainActor public protocol ObservableObject: AnyObject {}
@MainActor public final class ObjectPublisher { public func send() {} }
public extension ObservableObject { var objectWillChange: ObjectPublisher { ObjectPublisher() } }
@propertyWrapper @MainActor public struct Published<Value> {
 public var wrappedValue: Value
 public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
 public init() where Value: ExpressibleByNilLiteral { self.wrappedValue = nil }
}
@MainActor public final class AnyCancellable {
 private let cancelBody: () -> Void
 public init(_ cancel: @escaping () -> Void) { cancelBody = cancel }
 public func cancel() { cancelBody() }
}
@MainActor public final class PassthroughSubject<Value, Failure: Error> {
 private var callbacks: [UUID: (Value) -> Void] = [:]
 public init() {}
 public func send(_ value: Value) { for callback in Array(callbacks.values) { callback(value) } }
 public func sink(receiveValue: @escaping (Value) -> Void) -> AnyCancellable {
   let id = UUID(); callbacks[id] = receiveValue
   return AnyCancellable { [weak self] in self?.callbacks.removeValue(forKey: id) }
 }
}
''')
            dependencies=', "SwiftUI", "Combine"'
            extra='.target(name:"Combine"),.target(name:"SwiftUI",dependencies:["Combine"]),'
        (pkg/'Package.swift').write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"ContentLoadPortable",platforms:[.macOS(.v13)],targets:[
{extra}
.target(name:"LakeOfFireCore"),.target(name:"SwiftUIWebView"),
.target(name:"LakeOfFireContent",dependencies:["LakeOfFireCore","SwiftUIWebView"{dependencies}]),
.testTarget(name:"ContentTests",dependencies:["LakeOfFireContent"{dependencies}])
],swiftLanguageModes:[.v5])
''')
        report['inputs']={str(p):identity(p) for p in [args.source,args.tests,HERE/'Collaborators.swift',HERE/'run.py']}
        expected=json.loads((HERE/'expected-tests.json').read_text())
        if re.findall(r'\bfunc (test\w+)\(',args.tests.read_text())!=expected:
            raise ValueError('Authored methods differ from explicit roster')
        version=command(['swift','--version'],pkg,output,'compiler',15)
        if version: raise ValueError('Compiler unavailable')
        report['swift']=(output/'compiler.out').read_text().strip()
        argv=['swift','test','--jobs','1','--disable-swift-testing','--configuration',report['configuration'],
              '-Xswiftc','-strict-concurrency=complete']
        if not args.direct_resolver: argv+=['-Xswiftc','-DREADER_CONTENT_PORTABLE']
        if not args.allow_warnings: argv+=['-Xswiftc','-warnings-as-errors']
        if args.thread_sanitizer: argv+=['--sanitize','thread']
        step=dict(argv=argv,exit=None);report['commands'].append(step)
        step['exit']=command(argv,pkg,output,'tests',150)
        with (output/'tests.out').open() as lines: report['results']=verify(lines,step['exit'],expected)
        report['complete']=True;report['passed']=report['results']['failed']==0
    except Exception as e: report['error']=repr(e)
    (output/'RESULTS.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['complete','passed','results','error'] if k in report},indent=2))
    return 0 if report['passed'] else 1 if report['complete'] else 2
if __name__=='__main__': raise SystemExit(main())
