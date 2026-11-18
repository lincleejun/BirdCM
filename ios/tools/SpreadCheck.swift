import Foundation
@main struct SpreadCheck {
    static func main() throws {
        let args=CommandLine.arguments
        let sci=try String(contentsOfFile:args[2],encoding:.utf8).split(separator:"\n").map{String($0.split(separator:"\t")[0])}
        let geo=try Geo(weights:URL(fileURLWithPath:args[1]),scientific:sci)
        let places=[Place(lat:36.6,lon:-121.9,label:"",source:"photo"),Place(lat:37.2,lon:-119.5,label:"美国 · 加利福尼亚州",source:"region")]
        var results=[[String:[Double]]]()
        for p in places {let s=try geo.spread(p,date:"2026-11-14");results.append(["wide":s.wide,"typical":s.typical])}
        try JSONEncoder().encode(results).write(to:URL(fileURLWithPath:args[3]))
    }
}
