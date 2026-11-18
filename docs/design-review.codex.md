结论：**总体方向可行，但队列一致性、RAW 解码方案和真实模型验收需要先改，再开始完整实现。** SQLite、SSE、React 都可以保留；主要风险在状态边界和未经验证的性能假设。

以下按优先级排序。引用行号均对应当前文件；这是设计审查，尚未实现，因此所列问题包含设计未定义、实现时容易出错的边界。

1. **【must-fix】停止／继续没有定义旧任务何时失效，会重复处理或覆盖结果。**  
   [design.md:85](/Users/outman/workspace/personal/bird/BirdCM/docs/design.md:85) 同时存在解码预取、GPU 批次和后处理。“当前批完成后，把 `working` 退回 `queued`”不足以区分哪些任务仍在运行。立即继续后，旧任务可能晚到并覆盖新结果；有界队列满时，生产者阻塞也可能让停止永久等待。  
   **建议：**只设一个全局调度器，明确 `queued → running → stopping → paused → finalizing → completed`。停止先停止领取任务，再提交允许完成的批次，取消或丢弃其他在途输出，最后才进入 `paused`。`resume` 必须幂等，不能另起第二个消费者。队列读写必须能感知停止和异常，不能靠无限阻塞的 `put/get`。崩溃后允许未提交的计算重做，但数据库提交必须幂等。

2. **【must-fix】SSE 的持久化信息不够，无法兑现“断线后恢复完整界面”。**  
   [design.md:81](/Users/outman/workspace/personal/bird/BirdCM/docs/design.md:81) 只记录每张完成时的 `photo_id`，没有定义失败、暂停、恢复、最终星级和比例修改的补发。典型情况是最后一张结果已发送，星级随后更新，但客户端一直显示“待定星级”。快照中的行和最新序号若不在同一个读事务里获取，也可能漏更新。  
   **建议：**
   - 结果更新与事件写入同一事务；最终星级、汇总和完成状态也原子提交。
   - 快照与游标来自同一数据库读快照。
   - SSE 每条带 `id: n`；首次连接使用 `after`，自动重连优先读取 `Last-Event-ID`。浏览器不会自动修改原 URL 的 `after` 参数，见 [WHATWG 规范](https://html.spec.whatwg.org/multipage/server-sent-events.html)。
   - 用少量事件类型即可：照片变更、扫描状态变更、星级重算完成；最后一种让客户端重新取快照。
   - 客户端按序号去重，完成后主动关闭连接。慢客户端、关闭页面都不能阻塞或终止扫描。

3. **【must-fix】“所有照片已完成”和“整批已完成”必须分开恢复。**  
   [design.md:91](/Users/outman/workspace/personal/bird/BirdCM/docs/design.md:91) 如果最后一张已写库、标星之前引擎崩溃，启动时只恢复 `working` 无法解决：此时没有 `queued`，但整批没有星级。  
   **建议：**将 `finalizing` 持久化；启动时对照片均已终结、整批尚未完成的扫描重新执行确定性的分组和标星。空文件夹、全失败、全淘汰也必须正常终结。补上这些崩溃点的假 pipeline 测试，以及重复 stop/resume、最后一批停止的竞态测试。

4. **【must-fix】复用键会静默复用错误结果。**  
   [design.md:90](/Users/outman/workspace/personal/bird/BirdCM/docs/design.md:90) 的 `(path, size, mtime)` 没包含地区、模型、名录、阈值、解码和算法版本。相同照片换了地区，鸟种和稀有度仍可能沿用旧值；旧星级和连拍组更不能跨批直接复用。  
   **建议：**增加结果版本指纹，至少包括文件签名、模型／数据摘要、处理配置和有效地区。第一版直接让指纹不同的结果失效即可，不必先做复杂的分层缓存。星级和连拍排名始终针对当前扫描重算。处理前重新检查文件签名，文件改变或丢失时明确报错。

5. **【must-fix】“半尺寸解码＋只取头部原尺寸”不是 rawpy 已提供的廉价路径。**  
   [design.md:51](/Users/outman/workspace/personal/bird/BirdCM/docs/design.md:51) 一方面要求第一阶段保留全尺寸像素，另一方面又希望先半尺寸、之后只解头部。这是两套不同方案。rawpy 的公开后处理参数提供 `half_size`，没有直接的 RGB 头部 ROI 解码参数；不能把读取 Bayer 局部后自行处理视为等价方案，见 [rawpy 参数文档](https://letmaik.github.io/rawpy/api/rawpy.Params.html)。参考应用 [decode.py:298](/Users/outman/workspace/personal/bioscan/gardener/service/decode.py:298) **已经用了半尺寸解码**，因此也不能假定现有 0.8 秒还能再靠 `half_size` 降一次。  
   **建议：**先比较两个实际方案：一次全尺寸解码；半尺寸检测后，对有效照片重新全尺寸解码，并在工作进程内只返回头部小块或清晰度值。不要跨进程传整张全尺寸 RGB。若第二方案胜出，流程必须明确包含 GPU 定位后的 CPU 清晰度阶段。

6. **【must-fix】15 分钟目标目前没有完整预算，“瓶颈是解码”尚未成立。**  
   目标需要端到端平均 **≥1.67 张／秒**。单路 0.8 秒解码对应 1,200 秒，但并行后瓶颈可能转移到检测、二次 RAW 解码、IPC 或内存带宽。两次 BioCLIP 按文档的 33–40 张／秒估算，总共约 75–91 秒，**不包含检测和其他步骤**。  
   此外，[MODELS.md:23](/Users/outman/workspace/personal/bioclip-bird/MODELS.md:23) 明确说明 int8 只是文件压缩，计算仍是浮点；示例还会展开为 float32，不能据 0.63 GB 推断运行内存。约 33MP RGB8 一张约 99 MB，32 张仅像素就约 3.2 GB，尚未计复制、解码器和模型激活。  
   **建议：**把性能验证提前到界面实现之前：先用代表性 ARW 跑完整链路，再跑 1,500 张，计入模型加载、EXIF、缩略图、清晰度、标星和数据库提交。记录阶段吞吐、首张结果时间和峰值内存。解码进程从 2／4／8 个测起，限制原生库线程；不要直接采用“CPU 核数−2”。检测与 BioCLIP 分别确定批大小，并为 OOM 提供缩小批次重试。

7. **【must-fix】单张识别的交互没有对应 API，也没有进入统一 GPU 调度。**  
   [design.md:146](/Users/outman/workspace/personal/bird/BirdCM/docs/design.md:146) 承诺切换鸟、手动画框和补充地区，但 `/api/identify` 只有上传操作，没有持久照片 ID、目标框或地区更新协议。若单张也排在整个扫描之后，会等待十几分钟；若直接调用模型，又会与批量争用 GPU。  
   **建议：**上传先创建稳定照片 ID，后续以该 ID 提交主体框／手动框／地区并更新同一条历史。所有推理共用一个模型工作线程，批量在批次边界让单张插队。参考 [run.py:3](/Users/outman/workspace/personal/bioscan/gardener/service/run.py:3) 的按块轮转思路即可，无须引入通用任务框架。明确上传原图保存、删除历史时清理以及失败记录的规则。

8. **【must-fix】坐标变换与 FocusLocation 的可信度没有定义，会同时影响主体、眼睛和星级。**  
   必须统一原图、摆正图、2048 帧、方形裁图、224 模型输入和浏览器显示之间的坐标。否则竖拍、镜像 EXIF、边缘框和方形补边都可能让头部取样错位。  
   更关键的是，ExifTool 对 `FocusLocation` 的说明指出：无法获取对焦位置时会使用图像中心。因此“49／49 能读到”不能证明每个值都是真实对焦点，见 [ExifTool Sony 实现](https://raw.githubusercontent.com/exiftool/exiftool/master/lib/Image/ExifTool/Sony.pm)。  
   **建议：**定义统一的摆正原图坐标协议，保存尺寸及裁剪变换；FocusLocation 按其记录的宽高归一化，再做旋转映射，并保留缺失／无效／可信度信息。不要因中心默认值或缺失值处罚照片。把“框外 3%”明确为哪种距离、相对哪个尺寸，定义重叠框的决胜规则。

9. **【must-fix】91%／97.5% 的验收不能由已有压缩模型成绩直接推出。**  
   [模型 README:30](/Users/outman/workspace/personal/bioclip-bird/README.md:30) 的成绩来自包含 SigLIP2 门控、检测和 BirdNET 先验的完整 Gardener 流程；独立示例则只验证已裁好的鸟图。新设计改变门控、主体选择、裁剪和可能的分辨率，因此需要重新端到端测量。  
   [design.md:61](/Users/outman/workspace/personal/bird/BirdCM/docs/design.md:61) 先截前五再做地区修正也有歧义：若只修正前五，会永远救不回视觉排名第六的正确物种。  
   **建议：**地区修正在完整候选分布上完成，再取前五；保存有效地点、日期和来源。明确无日期、无先验、名录映射缺失时的回退，以及“不确定／只报属”的规则。验收固定分母，并分别报告检测、主体选择、鸟种和最终淘汰率，避免新门控误杀被隐藏。

10. **【must-fix】localhost 安全方向正确，但“是本机”必须改成严格同源规则。**  
    [design.md:112](/Users/outman/workspace/personal/bird/BirdCM/docs/design.md:112) 如果接受所有 localhost 端口的 Origin，其他本地网页服务也能操作它；如果 GET 一律要求 Origin，又会误伤正常图片和同源请求。按 ID 取图限制了路径输入，但不能替代访问控制。  
    **建议：**生产前后端同源；Host 使用精确白名单，带 Origin 的请求校验完整的 scheme、host、port，拒绝 `null` 和异源写操作。缺失 Origin 的写请求应有明确的 Referer／会话令牌策略，不能直接放行；普通图片 GET 则另行处理。不要配置宽泛 CORS。相关原则见 [OWASP CSRF 指南](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html)。  
    同时限制上传体积和像素数，上传使用自生成文件名；路径不拼接进 shell 或 AppleScript。规范化缓存／数据目录，防止环境变量把它们配置到原片目录内，破坏“不写原片文件夹”的承诺。

11. **【should-fix】“单张失败不影响其他照片”需要覆盖进程崩溃和批次失败。**  
    [design.md:92](/Users/outman/workspace/personal/bird/BirdCM/docs/design.md:92) 只描述普通异常。LibRaw 原生崩溃会破坏整个进程池；一次 GPU 批次 OOM 也不能归咎于其中每张照片。参考 [run.py:31](/Users/outman/workspace/personal/bioscan/gardener/service/run.py:31) 已专门处理进程池重建。  
    **建议：**加入池重建、有限重试、批次拆分及坏文件隔离；元数据缺失按字段降级。为解码和 ExifTool 设置超时，明确致命引擎错误如何暂停扫描，而不是把剩余全部照片标成坏片。SQLite 用专属写连接或单写线程、短事务；不要跨线程直接共享默认连接，SSE 也不能长期持有读事务。

12. **【should-fix】标星仍缺一份可执行规格，不能直接搬原型。**  
    原型 [desktop.html:439](/Users/outman/workspace/personal/bird/BirdCM/docs/prototype/desktop.html:439) 会把受三星限制的照片不断降为两星，可能超出两星目标；还把不确定分类纳入物种保底。PRD 又同时要求“太糊淘汰”和 0 星，需要明确边界。  
    **建议：**定义合格照片集合、比例分母、名额取整、并列顺序、封顶与保底优先级，以及保底允许超额多少。只给已确认物种保底。连拍按拍摄时间排序，处理亚秒、缺失时间、多相机和“两秒”边界，不能按解码完成顺序分组。清晰度缺失不等于零；原型的 0.70／0.45 也不能直接当真实阈值。先用主人留片验证指标，再固定权重。

13. **【should-fix】exiftool 第一版可以保留，没必要现在重写 Sony 解析。**  
    纯 Python 读四个整数本身不难，难在 MakerNote 定位、字节序、格式变体和无效值语义。当前也没有证据表明它是吞吐瓶颈。  
    **建议：**保留一个受控的常驻 ExifTool 服务，串行提交批量元数据请求，做响应匹配、超时、退出重启和 stderr 消费；别让多个线程交错写同一协议流。启动时检查依赖并给安装说明。未来若安装体验确实成为问题，再以现有样本做差分验证后替换；无需先建通用元数据插件层。

14. **【should-fix】“完全按原型”与排队行只有文件名存在明确冲突。**  
    [prototype/README.md:18](/Users/outman/workspace/personal/bird/BirdCM/docs/prototype/README.md:18) 要求排队照片也能预览大图和参数，而设计把这些推迟到正式处理。  
    **建议：**列表立即显示文件名；选中排队照片时按需优先生成预览和读取元数据，不必为整批先做第二遍解码。原型的 `id < done` 也只能用于演示，生产前端必须读取每行状态，因为并行处理会乱序完成且存在失败。另补全 `PhotoResult` 字段契约：中文名来源、候选、标星理由、组内排名、未知值、地区来源及失败信息；目前模型名录并未提供中文名字段。

15. **【optional】React 不重，应该删的是不必要的调度和扩展能力。**  
    **建议保留 Vite＋React＋TypeScript。** 三个视图、增量结果、排序筛选和弹窗已足以受益；保持无状态库、无路由库即可。`content-visibility` 只减少布局绘制，仍要用稳定行 key、懒加载图片，并合并短时间内的事件更新。虚拟列表等实测后再加。  
    可以直接删掉“每扫描一个线程”、固定 32 张批次、无条件全尺寸像素留存，以及第一版多检测器热插拔能力；先固定一种经验证的检测器。保留 SQLite 和简单事件日志。美学、稀有度等已经是明确要求，不能为了简化擅自删除；也不应提前添加移动共享层、XMP、eBird 或通用插件系统。

第 8 节六问的直接回答：

1. **队列：**有竞态和恢复缺口；采用单调度器、停止屏障、原子提交、可恢复最终化和完整 SSE 游标协议。
2. **解码／性能：**半尺寸可行，“廉价原尺寸头部 ROI”尚未成立；先验证完整解码路径和受限并行，15 分钟目前只能算目标。
3. **ExifTool：**第一版接受，保留；优先修正 FocusLocation 语义与生命周期管理。
4. **安全：**现有描述不够具体；严格同源规则、写操作保护、上传限制和路径边界补齐后适合该本地应用。
5. **React：**不过重，建议保留。
6. **可删除：**每扫描线程、过早的检测器扩展、固定批大小、全尺寸像素跨阶段长期留存；已明确要求的产品功能应保留。

全程未修改文件。未运行真实模型或 M4 Max 性能测试，也未复核“49／49”原始样本；吞吐和对焦点有效性仍需实测。