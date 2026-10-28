import Foundation
import Security
@main struct NativeSetupTests {
 static func main() throws {
  let dir=URL(fileURLWithPath:CommandLine.arguments[1]);let pem=try Data(contentsOf:dir.appendingPathComponent("synthetic-cert.pem"))+Data(contentsOf:dir.appendingPathComponent("synthetic-key.pem"))
  func configuration(_ pem:Data,agent:String="BeebSyntheticTest") -> Data {Data("user_agent: \(agent)\ncertificate: |\n  \(pem.base64EncodedString())\n".utf8)}
  let config=configuration(pem)
  let one=try TwinVineDirectSetup.package(config),two=try TwinVineDirectSetup.package(config)
  assert(one.p12 != two.p12 && one.password != two.password)
  let data=Data(base64Encoded:one.p12)!;let rawKey = try TwinVineDirectSetup.block("PRIVATE KEY",in:pem);assert(data.range(of:rawKey)==nil)
  let identity=try UHDIdentityVault.importIdentity(data,password:one.password);var certificate:SecCertificate?;assert(SecIdentityCopyCertificate(identity,&certificate)==errSecSuccess)
  func rejects(_ name:String,_ action:()throws->Void){do {try action();fatalError("Accepted \(name)")}catch {print("PASS:",name)}}
  rejects("wrong password") {_ = try UHDIdentityVault.importIdentity(data,password:"incorrect")}
  rejects("corrupted package") {var bad=data;bad[bad.count-10] ^= 1;_ = try UHDIdentityVault.importIdentity(bad,password:one.password)}
  rejects("expired identity") {_ = try TwinVineDirectSetup.package(config,now:Date(timeIntervalSince1970:4_102_444_800))}
  rejects("identity not yet valid") {_ = try TwinVineDirectSetup.package(config,now:Date(timeIntervalSince1970:0))}
  rejects("duplicate YAML field") {_ = try TwinVineDirectSetup.fields(config+Data("user_agent: duplicate\n".utf8))}
  rejects("header injection") {_ = try TwinVineDirectSetup.fields(configuration(pem,agent:"\"Beeb\\nInjected: bad\""))}
  rejects("YAML object tags") {_ = try TwinVineDirectSetup.fields(configuration(pem,agent:"!!python/object:unexpected {}"))}
  rejects("oversize response") {_ = try TwinVineDirectSetup.fields(Data(repeating:65,count:131073))}
  rejects("invalid certificate base64") {_ = try TwinVineDirectSetup.fields(Data("user_agent: Beeb\ncertificate: invalid***\n".utf8))}
  rejects("indefinite DER length") {_ = try TwinVineDirectSetup.DER.read(Data([0x30,0x80,0,0]))}
  rejects("truncated DER") {_ = try TwinVineDirectSetup.DER.read(Data([0x30,0x82,0xff,0xff,0]))}
  let other=try Data(contentsOf:dir.appendingPathComponent("synthetic-other-key.pem"))
  rejects("mismatched key") {_ = try TwinVineDirectSetup.package(configuration(try Data(contentsOf:dir.appendingPathComponent("synthetic-cert.pem"))+other))}
  print("PASS: valid encrypted native package, randomisation, exact-key matching and Apple identity import.")
 }
}
