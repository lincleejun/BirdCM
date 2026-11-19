import XCTest

/// Shared helpers for the UI flows. The flows are split into classes by area so parallel testing can spread them over
/// simulator clones; screenshots keep the old `-[Flows <test>]-<name>.png` names.
/// UI fixtures exercise presentation; real inference and cached re-ranking have separate engine checks.
class FlowCase: XCTestCase {
    let app=XCUIApplication()
    var env:[String:String] {ProcessInfo.processInfo.environment}
    var image:String {Bundle(for:FlowCase.self).resourceURL!.appendingPathComponent("Fixtures/photo-0.jpg").path}
    override func setUp(){continueAfterFailure=false}
    func element(_ id:String)->XCUIElement {
        let matches=app.descendants(matching:.any).matching(identifier:id)
        return matches.allElementsBoundByIndex.first(where:{$0.isHittable}) ?? matches.firstMatch
    }
    /// The keyboard's first-use tip; only there while a keyboard is up.
    func dismissTypingTip() {
        guard app.keyboards.firstMatch.exists else {return}
        let spring=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        for root in [app,spring] {
            for label in ["Continue","继续","Not Now","以后","好"] {
                let button=root.buttons[label]
                if button.exists && button.isHittable {button.tap();return}
            }
        }
    }
    func launch(_ state:String="normal",extra:[String]=[],reset:Bool=true) {
        app.terminate();app.launchArguments=["-uiTesting","YES","-resetHistory",reset ? "YES":"NO","-fixtureImage",state=="multiple" ? image.replacingOccurrences(of:"photo-0.jpg",with:"photo-1.jpg"):image,"-fixtureState",state]+extra;app.launch()
        XCTAssertTrue(element("home.photos").waitForExistence(timeout:20))
    }
    /// Hittable is not enough: an element under the action/tab bar still reports hittable, so require its frame to clear them.
    func clear(_ e:XCUIElement,_ id:String) -> Bool {
        if ["result.photos","result.bottomPlace","result.delete","home.photos","home.camera"].contains(id) {return true}
        let bars=["result.photos","home.photos"].filter{$0 != id}.map{element($0)}+[app.tabBars.firstMatch]
        let limit=bars.filter{$0.exists && $0.isHittable && $0.frame.height>0}.map{$0.frame.minY}.min() ?? .infinity
        return e.frame.maxY <= limit+0.5 && e.frame.minY >= 0
    }
    func reveal(_ id:String)->XCUIElement {
        let e=element(id)
        for i in 0..<60 {
            if e.exists && e.isHittable && clear(e,id) {return e}
            // Short slow drags with a hold (no momentum overshoot); alternate start points so neither the bottom bar nor the pager swallows every attempt.
            let y=[0.62,0.45,0.7,0.35][i%4], x=i%8<4 ? 0.94:0.06, up = !(e.exists && e.frame.maxY < 90)
            // Every third try a fast system swipe: slow drags that start on a control inside a sheet may not scroll.
            // Only while the row is not built yet; once it exists, slow drags place it without overshooting.
            if i%3==2 && !e.exists {app.swipeUp();continue}
            app.coordinate(withNormalizedOffset:CGVector(dx:x,dy:up ? y:y-0.25)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:x,dy:up ? y-0.25:y)),withVelocity:.slow,thenHoldForDuration:0.1)
        }
        try? shot("unreachable-"+id);XCTFail("Missing or unreachable: \(id)");return e
    }
    func shot(_ name:String) throws {
        dismissTypingTip()
        let s=XCUIScreen.main.screenshot(),a=XCTAttachment(screenshot:s);a.name=name;a.lifetime = .keepAlways;add(a)
        if let folder=env["SCREENSHOT_DIR"] {
            let dir=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let test=self.name.replacingOccurrences(of:"[\(type(of:self)) ",with:"[Flows ")
            try s.pngRepresentation.write(to:dir.appendingPathComponent(test.replacingOccurrences(of:"/",with:"-")+"-"+name+".png"))
        }
    }
    func fixture() {
        reveal("home.more").tap();XCTAssertTrue(element("settings.done").waitForExistence(timeout:5));reveal("home.diagnostics").tap()
        XCTAssertTrue(element("diagnostics.fixture").waitForExistence(timeout:5));element("diagnostics.fixture").tap()
    }
    func outcome(_ id:String="result.name",file:StaticString=#filePath,line:UInt=#line) {XCTAssertTrue(element(id).waitForExistence(timeout:10),"missing \(id)",file:file,line:line)}
    /// Polls every 0.1 s; a predicate expectation re-evaluates only about once a second.
    func until(_ what:String,_ timeout:Double=10,file:StaticString=#filePath,line:UInt=#line,_ done:()->Bool) {
        let end=Date().addingTimeInterval(timeout)
        while !done() {if Date()>end {XCTFail("timed out: \(what)",file:file,line:line);return};usleep(100_000)}
    }
    func label(_ e:XCUIElement,contains text:String,_ timeout:Double=10,file:StaticString=#filePath,line:UInt=#line) {
        until("label contains \(text)",timeout,file:file,line:line) {e.exists && e.label.contains(text)}
    }
    func tab(_ id:String,_ label:String) {
        let byID=app.buttons[id]
        if byID.exists && byID.isHittable {byID.tap()} else {app.tabBars.buttons[label].firstMatch.tap()}
    }
    func endSearch() {for label in ["取消","Cancel"] {let b=app.navigationBars.buttons[label].firstMatch;if b.exists && b.isHittable {b.tap();return}}}
    func segment(_ label:String) {app.segmentedControls.buttons[label].firstMatch.tap()}
    func search(_ text:String) {let f=app.searchFields.firstMatch;XCTAssertTrue(f.waitForExistence(timeout:5));f.tap();f.typeText(text);dismissTypingTip()}
    var rows:[String] {app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'history.item.'")).allElementsBoundByIndex.filter{$0.isHittable}.map(\.identifier)}
    func pick(){fixture();outcome()}
    func back(){
        let buttons=app.navigationBars.buttons.allElementsBoundByIndex
        guard let button=buttons.first(where:{$0.isHittable && $0.identifier != "home.more" && $0.label != "结果操作"}) else {XCTFail("No visible back button");return}
        button.tap()
    }
}
