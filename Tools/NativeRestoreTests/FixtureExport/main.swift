import Foundation
import LakeOfFireReader
FileHandle.standardOutput.write(try nativeRestoreJSONFixtures())
FileHandle.standardOutput.write(Data([10]))
