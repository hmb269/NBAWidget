import SwiftUI

/// 小组件配色：底色（渐变）+ 用深色还是浅色的文字
struct WidgetThemeDef: Identifiable {
    let id: Int
    let name: String
    let dark: Bool?          // nil = 跟随系统
    let top: UInt32
    let bottom: UInt32

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [Self.color(top), Self.color(bottom)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

enum WidgetThemes {
    static let all: [WidgetThemeDef] = [
        WidgetThemeDef(id: 0, name: "跟随系统", dark: nil, top: 0xFFFFFF, bottom: 0x1C1C1C),
        WidgetThemeDef(id: 1, name: "深色", dark: true, top: 0x1C1C1C, bottom: 0x1C1C1C),
        WidgetThemeDef(id: 2, name: "白色", dark: false, top: 0xFFFFFF, bottom: 0xFFFFFF),
        // 深色系
        WidgetThemeDef(id: 3, name: "午夜蓝", dark: true, top: 0x13244D, bottom: 0x0B1530),
        WidgetThemeDef(id: 4, name: "深海青", dark: true, top: 0x0B4A55, bottom: 0x062A31),
        WidgetThemeDef(id: 5, name: "森林绿", dark: true, top: 0x1C4A30, bottom: 0x0E2A1B),
        WidgetThemeDef(id: 6, name: "葡萄紫", dark: true, top: 0x45225F, bottom: 0x241035),
        WidgetThemeDef(id: 7, name: "酒红", dark: true, top: 0x5A1528, bottom: 0x300A15),
        WidgetThemeDef(id: 8, name: "摩卡", dark: true, top: 0x4A372C, bottom: 0x2A1E17),
        WidgetThemeDef(id: 9, name: "极光", dark: true, top: 0x0E4A4F, bottom: 0x2E1C5A),
        WidgetThemeDef(id: 10, name: "晚霞", dark: true, top: 0x5C2A4A, bottom: 0x5A3418),
        WidgetThemeDef(id: 11, name: "石墨", dark: true, top: 0x3A3F47, bottom: 0x1E2126),
        // 浅色系
        WidgetThemeDef(id: 12, name: "奶油", dark: false, top: 0xFFF9EC, bottom: 0xF8EBCF),
        WidgetThemeDef(id: 13, name: "樱花", dark: false, top: 0xFFF0F4, bottom: 0xF9D3E0),
        WidgetThemeDef(id: 14, name: "薄荷", dark: false, top: 0xEEFBF5, bottom: 0xCDEFE2),
        WidgetThemeDef(id: 15, name: "天空", dark: false, top: 0xEEF6FF, bottom: 0xCFE3FB),
        WidgetThemeDef(id: 16, name: "薰衣草", dark: false, top: 0xF5F0FF, bottom: 0xDDD2F8),
        WidgetThemeDef(id: 17, name: "蜜桃", dark: false, top: 0xFFF3EA, bottom: 0xFAD5C0),
    ]

    static func def(_ id: Int) -> WidgetThemeDef { all.first { $0.id == id } ?? all[0] }
}
