//
//  CLPCEnergy.swift
//  Sensors
//
//  macOS 27 起 Energy Model 里的 CPU/ANE/DRAM 能量计数器（mJ）对没有 Apple 私有
//  entitlement 的进程完全冻结 —— 即使是 root 也一样（Stats 因此把 CPU Power 显示成
//  0.00W）。CLPC 驱动的 "Energy Counters"（nJ）仍然免特权可读，powermetrics 之外的
//  第三方工具（如 macmon）走的就是这条通道。
//
//  这些通道无法通过 IOReportCopyAllChannels 枚举出来，必须按芯片的
//  (index << 32 | key) 报告 ID 手工构造通道描述符后再订阅。
//

import Foundation
import IOKit

enum CLPCEnergy {
    private struct Keys {
        let cpu: UInt32
        let gpu: UInt32
        let ane: UInt32
        let ram: UInt32
    }

    /// macOS 27 上各聚合计数器的 index（与 macmon 的 INDICES_27 一致）
    private static let indexCPU: UInt32 = 16
    private static let indexGPU: UInt32 = 25
    private static let indexANE: UInt32 = 24
    private static let indexRAM: UInt32 = 26

    /// 每个 CLPC 驱动的聚合计数器 key（来自 macOS 27 的 CLPC 驱动表）
    private static let keys: [String: Keys] = [
        "com.apple.driver.AppleT6000CLPCv3": Keys(cpu: 0x4747_9059, gpu: 0x4519_bf1e, ane: 0x9aaa_17f8, ram: 0xd6ca_0cfb),
        "com.apple.driver.AppleT6002CLPC": Keys(cpu: 0xb501_816b, gpu: 0x9e2c_3e8b, ane: 0x14d5_a574, ram: 0x7670_4b08),
        "com.apple.driver.AppleT6020CLPC": Keys(cpu: 0xe301_cd75, gpu: 0x8f34_cc7a, ane: 0x7415_fb0f, ram: 0x2624_4bb6),
        "com.apple.driver.AppleT6022CLPC": Keys(cpu: 0x76f5_fd21, gpu: 0x9062_4499, ane: 0x3c09_7307, ram: 0xe8f2_ddf9),
        "com.apple.driver.AppleT6030CLPC": Keys(cpu: 0xbe03_a01a, gpu: 0x472d_6c9c, ane: 0xb899_0c38, ram: 0x2380_9c0f),
        "com.apple.driver.AppleT6031CLPC": Keys(cpu: 0xd81e_0084, gpu: 0x1085_f98b, ane: 0x313a_3be1, ram: 0x65ff_699d),
        "com.apple.driver.AppleT6032CLPC": Keys(cpu: 0xf4a2_1308, gpu: 0x85e8_0513, ane: 0x63dc_8e25, ram: 0x63dc_aae5),
        "com.apple.driver.AppleT6041CLPC": Keys(cpu: 0x263c_f1f0, gpu: 0x22e4_cf59, ane: 0x7849_fb5c, ram: 0xfe93_2624),
        "com.apple.driver.AppleT6050CLPC": Keys(cpu: 0xd3ab_60bb, gpu: 0x27cd_4ce5, ane: 0x8c0f_1c59, ram: 0xf3c8_1737),
        "com.apple.driver.AppleT6050dCLPC": Keys(cpu: 0x18b3_010e, gpu: 0xedec_a11a, ane: 0x188b_d883, ram: 0xa331_96f9),
        "com.apple.driver.AppleT8103CLPCv3": Keys(cpu: 0x2cdd_31f2, gpu: 0x21be_cf42, ane: 0x0667_fb81, ram: 0xc0c2_0839),
        "com.apple.driver.AppleT8112CLPC": Keys(cpu: 0xb543_5137, gpu: 0x638d_9d52, ane: 0xea08_9c36, ram: 0x8b6e_0faa),
        "com.apple.driver.AppleT8122CLPC": Keys(cpu: 0x54b5_1c99, gpu: 0xce2d_d9dc, ane: 0x960a_fe2f, ram: 0x0b96_41d3),
        "com.apple.driver.AppleT8132CLPC": Keys(cpu: 0x4a85_4d94, gpu: 0x3b3e_3b79, ane: 0x1ff4_a9ec, ram: 0x9a44_d225),
        "com.apple.driver.AppleT8140CLPC": Keys(cpu: 0x9bf5_4436, gpu: 0xef70_589c, ane: 0x569d_941b, ram: 0x035f_5005),
        "com.apple.driver.AppleT8142CLPC": Keys(cpu: 0x4370_8744, gpu: 0x6a01_0933, ane: 0xbc5e_fdf0, ram: 0xe136_33aa),
        "com.apple.driver.AppleT8152CLPC": Keys(cpu: 0x485d_4bfc, gpu: 0x1178_4654, ane: 0x9380_c6bb, ram: 0xe17c_13bf),
    ]

    /// 需要 macOS 27+（此前 Energy Model 本身可用）
    static var isNeeded: Bool {
        #if arch(arm64)
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        #else
        return false
        #endif
    }

    /// 构造可直接塞进 IORepot 订阅的 CLPC 通道描述符
    static func channels() -> [CFMutableDictionary] {
        guard self.isNeeded else { return [] }

        var out: [CFMutableDictionary] = []
        for (driver, bundle) in self.drivers() {
            guard let keys = self.keys[bundle] else { continue }
            let list: [(UInt32, UInt32, String)] = [
                (self.indexCPU, keys.cpu, "CPU Energy"),
                (self.indexGPU, keys.gpu, "GPU Energy"),
                (self.indexANE, keys.ane, "ANE"),
                (self.indexRAM, keys.ram, "DRAM")
            ]
            for (index, key, name) in list {
                let id = (UInt64(index) << 32) | UInt64(key)
                out.append(Self.channel(driver: driver, id: id, name: name))
            }
        }
        return out
    }

    /// 找出所有 AppleCLPC 服务的 (registry entry id, CFBundleIdentifier)
    private static func drivers() -> [(UInt64, String)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLPC"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [(UInt64, String)] = []
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            var id: UInt64 = 0
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
               IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let properties = props?.takeRetainedValue() as? [String: Any],
               let bundle = properties["CFBundleIdentifier"] as? String {
                result.append((id, bundle))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }

    /// 单个通道字典：legend = [reportID, channelType, name]，unit = nJ
    private static func channel(driver: UInt64, id: UInt64, name: String) -> CFMutableDictionary {
        // IOReportTypes.h: type 1 (simple) | category 2 (power) << 16 | element count 1 << 32
        let channelType: Int64 = 1 | (2 << 16) | (1 << 32)
        // unit descriptor: scale 3 << 56 | 'nJ' == 118 << 32
        let unit: Int64 = (3 << 56) | (118 << 32)
        let legend: [Any] = [NSNumber(value: id), NSNumber(value: channelType), name as CFString]
        let info: [CFString: Any] = [("IOReportChannelUnit" as CFString): NSNumber(value: unit)]
        let raw: [CFString: Any] = [
            ("DriverID" as CFString): NSNumber(value: driver),
            ("DriverName" as CFString): ("AppleCLPC" as CFString),
            ("IOReportGroupName" as CFString): ("CLPC" as CFString),
            ("IOReportSubGroupName" as CFString): ("Energy Counters" as CFString),
            ("IOReportChannelInfo" as CFString): (info as CFDictionary),
            ("LegendChannel" as CFString): (legend as CFArray)
        ]
        // IOReport 的 getter 会往 channel 字典里回写缓存字段，必须是可变的
        return CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, raw as CFDictionary)!
    }
}
