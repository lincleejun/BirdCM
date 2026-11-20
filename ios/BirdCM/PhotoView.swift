import SwiftUI
import UIKit

struct PhotoView: UIViewRepresentable {
    let image: UIImage
    let record: Record
    let marks: Bool
    let drawing: Bool
    var neutral=false
    /// Opened zoomed onto this normalized window (once per record id); nil = the whole photo.
    var focus:[Double]?=nil
    var onSelect: (Int)->Void
    var onDraw: ([Double])->Void
    /// A single tap outside every box (not drawing): the result hero opens the image viewer with it.
    var onTap:(()->Void)?=nil
    func makeUIView(context: Context) -> ZoomPhoto {ZoomPhoto()}
    func updateUIView(_ view: ZoomPhoto,context:Context) {
        view.onTap=onTap;if view.id != record.id {view.focus=focus}
        view.update(image:image,record:record,marks:marks,drawing:drawing)
        view.backgroundColor=neutral ? .secondarySystemBackground:.black
        view.canvas.backgroundColor=view.backgroundColor
        view.select=onSelect;view.drawBox=onDraw
    }
}
final class PhotoCanvas: UIView {
    var image: UIImage?
    var record: Record?
    var marks=true
    var draft: CGRect?
    override func draw(_ rect: CGRect) {
        guard let ctx=UIGraphicsGetCurrentContext() else{return}
        image?.draw(in:bounds)
        guard let record else{return}
        if marks {
            for (i,b) in record.boxes.enumerated() {
                let r=CGRect(x:b[0]*bounds.width,y:b[1]*bounds.height,width:(b[2]-b[0])*bounds.width,height:(b[3]-b[1])*bounds.height)
                ctx.setLineWidth(3);ctx.setStrokeColor(UIColor.black.cgColor);ctx.stroke(r)
                ctx.setLineWidth(1.5);ctx.setStrokeColor((i==record.selected ? UIColor.systemYellow:UIColor.white).cgColor)
                ctx.setLineDash(phase:0,lengths:i==record.selected ? []:[5,4]);ctx.stroke(r);ctx.setLineDash(phase:0,lengths:[])
            }
            for (p,color) in [(record.result?.eye,UIColor.systemRed),(record.result?.beak,UIColor.systemCyan)] {
                if let p {let r=CGRect(x:p[0]*bounds.width-5,y:p[1]*bounds.height-5,width:10,height:10);ctx.setStrokeColor(UIColor.black.cgColor);ctx.setLineWidth(3);ctx.strokeEllipse(in:r);ctx.setStrokeColor(color.cgColor);ctx.setLineWidth(1.5);ctx.strokeEllipse(in:r)}
            }
        }
        if let draft {ctx.setStrokeColor(UIColor.systemYellow.cgColor);ctx.setLineWidth(2);ctx.stroke(draft)}
    }
}
final class ZoomPhoto: UIScrollView,UIScrollViewDelegate,UIGestureRecognizerDelegate {
    let canvas=PhotoCanvas()
    var select: ((Int)->Void)?
    var drawBox: (([Double])->Void)?
    var onTap: (()->Void)?
    var focus: [Double]?
    var drawing=false
    var start=CGPoint.zero
    var id: UUID?
    lazy var manual=UIPanGestureRecognizer(target:self,action:#selector(drag(_:)))
    override init(frame:CGRect) {
        super.init(frame:frame);delegate=self;minimumZoomScale=1;maximumZoomScale=5;bouncesZoom=true
        showsHorizontalScrollIndicator=false;showsVerticalScrollIndicator=false;backgroundColor = .black
        addSubview(canvas)
        let tap=UITapGestureRecognizer(target:self,action:#selector(tap(_:)));canvas.addGestureRecognizer(tap)
        let double=UITapGestureRecognizer(target:self,action:#selector(zoom(_:)));double.numberOfTapsRequired=2;canvas.addGestureRecognizer(double);tap.require(toFail:double)

        canvas.addGestureRecognizer(manual);manual.isEnabled=false
        canvas.accessibilityIdentifier="result.canvas";canvas.isAccessibilityElement=true;canvas.accessibilityLabel=String(localized:"鸟的照片");canvas.accessibilityHint=String(localized:"双击放大，主体切换和画框按钮在照片下方")
        canvas.isUserInteractionEnabled=true
    }
    required init?(coder:NSCoder){fatalError()}
    func update(image:UIImage,record:Record,marks:Bool,drawing:Bool) {
        if id != record.id {setZoomScale(1,animated:false);id=record.id;canvas.contentScaleFactor=traitCollection.displayScale}
        canvas.image=image;canvas.record=record;canvas.marks=marks;self.drawing=drawing;manual.isEnabled=drawing
        panGestureRecognizer.isEnabled = !drawing && zoomScale>1
        canvas.setNeedsDisplay();setNeedsLayout()
        canvas.accessibilityCustomActions=[UIAccessibilityCustomAction(name:String(localized:"放大或还原照片"),actionHandler:{[weak self] _ in guard let self else{return false};self.setZoomScale(self.zoomScale>1 ? 1:2,animated:true);return true})]
            + (onTap == nil ? []:[UIAccessibilityCustomAction(name:String(localized:"查看大图"),actionHandler:{[weak self] _ in self?.onTap?();return true})])
    }
    /// The canvas is the image aspect-fitted in the bounds and kept centred, so a full-screen viewer zooms the whole photo
    /// (callers that already size the view to the image's aspect see no change).
    override func layoutSubviews(){
        super.layoutSubviews()
        if zoomScale==1{canvas.frame=CGRect(origin:.zero,size:ImageViewer.fit(canvas.image?.size ?? bounds.size,in:bounds.size));contentSize=canvas.frame.size}
        recenter()
        if let f=focus,bounds.width>0,canvas.bounds.width>0 {focus=nil;zoom(to:ImageViewer.zoomRect(f,in:canvas.bounds.size),animated:false);sharpen()}
    }
    func recenter(){canvas.center=CGPoint(x:max(contentSize.width,bounds.width)/2,y:max(contentSize.height,bounds.height)/2)}
    /// draw(_:) renders at the canvas's own size; when zoomed, render more pixels (never more than the image has).
    func sharpen(){
        let px=(canvas.image.map{$0.size.width*$0.scale} ?? 0)/max(1,canvas.bounds.width), screen=traitCollection.displayScale
        let want=max(screen,min(zoomScale*screen,px))
        if abs(canvas.contentScaleFactor-want)>0.01 {canvas.contentScaleFactor=want;canvas.setNeedsDisplay()}
    }
    func viewForZooming(in scrollView:UIScrollView)->UIView?{canvas}
    func scrollViewDidZoom(_ scrollView:UIScrollView){panGestureRecognizer.isEnabled = !drawing && zoomScale>1;recenter()}
    func scrollViewDidEndZooming(_ scrollView:UIScrollView,with view:UIView?,atScale scale:CGFloat){sharpen()}
    @objc func zoom(_ g:UITapGestureRecognizer){guard !drawing else{return};setZoomScale(zoomScale>1 ? 1:2,animated:!UIAccessibility.isReduceMotionEnabled)}
    @objc func tap(_ g:UITapGestureRecognizer){
        guard !drawing,let r=canvas.record else{return}
        let p=g.location(in:canvas),x=p.x/canvas.bounds.width,y=p.y/canvas.bounds.height
        if let i=r.boxes.indices.reversed().first(where:{let b=r.boxes[$0];return x>=b[0] && x<=b[2] && y>=b[1] && y<=b[3]}) {select?(i)} else {onTap?()}
    }
    @objc func drag(_ g:UIPanGestureRecognizer){
        let raw=g.location(in:canvas),p=CGPoint(x:min(max(0,raw.x),canvas.bounds.width),y:min(max(0,raw.y),canvas.bounds.height))
        if g.state == .began{start=p}
        canvas.draft=CGRect(x:min(start.x,p.x),y:min(start.y,p.y),width:abs(start.x-p.x),height:abs(start.y-p.y));canvas.setNeedsDisplay()
        if g.state == .ended,let r=canvas.draft {canvas.draft=nil;if r.width>=12 && r.height>=12{drawBox?([r.minX/canvas.bounds.width,r.minY/canvas.bounds.height,r.maxX/canvas.bounds.width,r.maxY/canvas.bounds.height])}}
        if g.state == .cancelled{canvas.draft=nil}
    }
}
