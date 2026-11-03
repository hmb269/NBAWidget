import Foundation
import CoreBluetooth

/// 血糖仪里读出来的一条记录
struct MeterReading {
    var seq: UInt16
    var date: Date
    var mmol: Double
    var meal: UInt8?   // 1 餐前 2 餐后 3 空腹 4 随机 5 睡前（蓝牙标准的编号）
}

/// 通过蓝牙标准「血糖服务」（Glucose Profile，0x1808）读取罗氏智航里存的全部记录。
/// 流程：找到血糖仪 → 连接 → 订阅「测量值 / 测量补充信息 / 记录控制」→ 发「把所有记录发过来」→ 收完断开。
/// 第一次连接时 iOS 会弹出配对框，输入血糖仪背面的 PIN 码。
final class AccuChekSync: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "还没同步过"
    @Published var busy = false

    /// 读完后回调：记录 + 血糖仪序列号（用于去重）
    var onFinished: (([MeterReading], String) -> Void)?

    private let glucoseService = CBUUID(string: "1808")
    private let measurementUUID = CBUUID(string: "2A18")
    private let contextUUID = CBUUID(string: "2A34")
    private let racpUUID = CBUUID(string: "2A52")
    private let deviceInfoService = CBUUID(string: "180A")
    private let serialUUID = CBUUID(string: "2A25")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var racp: CBCharacteristic?
    private var notifyingCount = 0
    private var requested = false
    private var serial = "guide"
    private var measurements: [UInt16: MeterReading] = [:]
    private var meals: [UInt16: UInt8] = [:]
    private var timeoutWork: DispatchWorkItem?

    // MARK: 开始 / 结束

    func start() {
        guard !busy else { return }
        busy = true
        measurements = [:]
        meals = [:]
        notifyingCount = 0
        requested = false
        status = "正在打开蓝牙…"
        if let central, central.state == .poweredOn {
            scan()
        } else if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        }
        armTimeout(45, message: "没找到血糖仪。请按一下血糖仪的开机键让它亮屏，靠近手机再试")
    }

    /// 用户点「取消」：停止找蓝牙并断开
    func cancel() {
        guard busy else { return }
        finish(measurements.isEmpty ? "已取消" : "已取消（读到的 \(measurements.count) 条已保存）",
               deliver: !measurements.isEmpty)
    }

    private func finish(_ message: String, deliver: Bool) {
        timeoutWork?.cancel()
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        busy = false
        status = message
        if deliver {
            let list = measurements.values.map { r -> MeterReading in
                var r = r
                if r.meal == nil { r.meal = meals[r.seq] }
                return r
            }.sorted { $0.date < $1.date }
            onFinished?(list, serial)
        }
    }

    private func armTimeout(_ seconds: Double, message: String) {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.busy else { return }
            // 已经收到一些记录就照样保存
            self.finish(self.measurements.isEmpty ? message : "同步结束（读到 \(self.measurements.count) 条）",
                        deliver: !self.measurements.isEmpty)
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: 找设备

    private func scan() {
        guard let central else { return }
        // 手机已经和血糖仪配对过（比如之前小程序连过），可能已经连着
        if let p = central.retrieveConnectedPeripherals(withServices: [glucoseService]).first {
            connect(p)
            return
        }
        status = "正在寻找血糖仪…（请按一下血糖仪开机键）"
        central.scanForPeripherals(withServices: [glucoseService])
    }

    private func connect(_ p: CBPeripheral) {
        central?.stopScan()
        peripheral = p
        p.delegate = self
        status = "正在连接 \(p.name ?? "血糖仪")…"
        central?.connect(p)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard busy else { return }
        switch central.state {
        case .poweredOn: scan()
        case .poweredOff: finish("蓝牙没打开，请在控制中心打开蓝牙", deliver: false)
        case .unauthorized: finish("没有蓝牙权限：设置 → 阿波 → 打开蓝牙", deliver: false)
        case .unsupported: finish("这台设备不支持蓝牙", deliver: false)
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "已连接，正在读取…"
        armTimeout(60, message: "读取超时。如果弹出过配对框，请输入血糖仪背面的 PIN 码后再试")
        peripheral.discoverServices([glucoseService, deviceInfoService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish("连接失败：\(error?.localizedDescription ?? "未知原因")", deliver: false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard busy else { return }
        finish(measurements.isEmpty ? "血糖仪断开了，请再试一次" : "同步结束（读到 \(measurements.count) 条）",
               deliver: !measurements.isEmpty)
    }

    // MARK: 服务和特征

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            if s.uuid == glucoseService {
                peripheral.discoverCharacteristics([measurementUUID, contextUUID, racpUUID], for: s)
            } else if s.uuid == deviceInfoService {
                peripheral.discoverCharacteristics([serialUUID], for: s)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case measurementUUID, contextUUID:
                peripheral.setNotifyValue(true, for: c)
            case racpUUID:
                racp = c
                peripheral.setNotifyValue(true, for: c)   // 记录控制用 indicate
            case serialUUID:
                peripheral.readValue(for: c)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            // 加密特征第一次订阅会触发系统配对框；配对没完成会报这个错
            status = "需要配对：\(error.localizedDescription)"
            return
        }
        if characteristic.isNotifying { notifyingCount += 1 }
        // 测量值、补充信息、记录控制三个都订阅好了，再请求记录
        if notifyingCount >= 3 || (notifyingCount >= 2 && characteristic.uuid == racpUUID) {
            requestAllRecords()
        }
    }

    private func requestAllRecords() {
        guard !requested, let racp, let p = peripheral else { return }
        requested = true
        status = "正在读取血糖仪里的记录…"
        // 操作码 0x01「报告已存储的记录」，运算符 0x01「全部记录」
        p.writeValue(Data([0x01, 0x01]), for: racp, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case measurementUUID:
            if let r = Self.parseMeasurement(data) {
                measurements[r.seq] = r
                status = "已读到 \(measurements.count) 条…"
            }
        case contextUUID:
            if let (seq, meal) = Self.parseContext(data) { meals[seq] = meal }
        case racpUUID:
            let b = [UInt8](data)
            // 0x06 = 应答；第 4 个字节 0x01 成功，0x06 没有记录
            if b.count >= 4, b[0] == 0x06 {
                if b[3] == 0x01 || b[3] == 0x06 {
                    finish(measurements.isEmpty ? "血糖仪里没有记录" : "读取完成，共 \(measurements.count) 条",
                           deliver: !measurements.isEmpty)
                } else {
                    finish("血糖仪返回错误（代码 \(b[3])）", deliver: !measurements.isEmpty)
                }
            }
        case serialUUID:
            if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
               !s.isEmpty {
                serial = s
            }
        default: break
        }
    }

    // MARK: 数据解析（蓝牙标准格式）

    /// 16 位 SFLOAT：低 12 位尾数、高 4 位指数，都是有符号数
    static func sfloat(_ raw: UInt16) -> Double? {
        let m = Int(raw & 0x0FFF)
        if [0x07FF, 0x0800, 0x07FE, 0x0802, 0x0801].contains(m) { return nil } // 特殊值：无效 / 无穷
        let mantissa = m >= 0x0800 ? m - 0x1000 : m
        let e = Int(raw >> 12)
        let exponent = e >= 0x8 ? e - 0x10 : e
        return Double(mantissa) * pow(10, Double(exponent))
    }

    static func parseMeasurement(_ data: Data) -> MeterReading? {
        let d = [UInt8](data)
        guard d.count >= 10 else { return nil }
        let flags = d[0]
        var i = 1
        let seq = UInt16(d[i]) | UInt16(d[i + 1]) << 8; i += 2
        var c = DateComponents()
        c.year = Int(d[i]) | Int(d[i + 1]) << 8
        c.month = Int(d[i + 2]); c.day = Int(d[i + 3])
        c.hour = Int(d[i + 4]); c.minute = Int(d[i + 5]); c.second = Int(d[i + 6])
        i += 7
        var offsetMinutes = 0
        if flags & 0x01 != 0 {
            guard d.count >= i + 2 else { return nil }
            offsetMinutes = Int(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8)); i += 2
        }
        guard flags & 0x02 != 0, d.count >= i + 2 else { return nil } // 没有浓度的记录（比如质控液）跳过
        guard let conc = sfloat(UInt16(d[i]) | UInt16(d[i + 1]) << 8) else { return nil }
        // 单位：位 2 为 1 是 mol/L，为 0 是 kg/L
        let mmol = flags & 0x04 != 0 ? conc * 1000 : conc * 100_000 / 18.016
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        guard let base = cal.date(from: c) else { return nil }
        let date = base.addingTimeInterval(TimeInterval(offsetMinutes * 60))
        return MeterReading(seq: seq, date: date, mmol: (mmol * 10).rounded() / 10, meal: nil)
    }

    /// 测量补充信息里的「餐点」
    static func parseContext(_ data: Data) -> (UInt16, UInt8)? {
        let d = [UInt8](data)
        guard d.count >= 3 else { return nil }
        let flags = d[0]
        let seq = UInt16(d[1]) | UInt16(d[2]) << 8
        var i = 3
        if flags & 0x80 != 0 { i += 1 }        // 扩展标志
        if flags & 0x01 != 0 { i += 3 }        // 碳水
        guard flags & 0x02 != 0, d.count > i else { return nil }
        return (seq, d[i])
    }
}
