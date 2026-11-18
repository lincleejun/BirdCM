import Foundation
let args=CommandLine.arguments
let points=try JSONDecoder().decode([[Float]].self,from:Data(contentsOf:URL(fileURLWithPath:args[3])))
let net=try GeoNetwork(weights:URL(fileURLWithPath:args[1]),graphURL:URL(fileURLWithPath:args[2]))
var data=Data()
for start in stride(from:0,to:points.count,by:48) {
    let result=try net.predict(Array(points[start..<min(start+48,points.count)]))
    for var row in result {row.withUnsafeMutableBytes{data.append(contentsOf:$0)}}
}
try data.write(to:URL(fileURLWithPath:args[4]))
print("native fp32: \(points.count) points × 14082")
