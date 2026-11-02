import AppIntents

/// 小组件设置里可选的球队（显示名必须写成字面量，系统才能读到）
enum TeamOption: String, AppEnum {
    case phi = "PHI"
    case chi = "CHI"
    case bos = "BOS"
    case gsw = "GSW"
    case sac = "SAC"
    case phx = "PHX"
    case was = "WAS"
    case nyk = "NYK"
    case por = "POR"
    case lac = "LAC"
    case den = "DEN"
    case min = "MIN"
    case ind = "IND"
    case det = "DET"
    case lal = "LAL"
    case hou = "HOU"
    case mem = "MEM"
    case mia = "MIA"
    case uta = "UTA"
    case dal = "DAL"
    case tor = "TOR"
    case bkn = "BKN"
    case atl = "ATL"
    case mil = "MIL"
    case okc = "OKC"
    case sas = "SAS"
    case cle = "CLE"
    case orl = "ORL"
    case nop = "NOP"
    case cha = "CHA"

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "球队")
    static var caseDisplayRepresentations: [TeamOption: DisplayRepresentation] = [
        .phi: DisplayRepresentation(title: "76人"),
        .chi: DisplayRepresentation(title: "公牛"),
        .bos: DisplayRepresentation(title: "凯尔特人"),
        .gsw: DisplayRepresentation(title: "勇士"),
        .sac: DisplayRepresentation(title: "国王"),
        .phx: DisplayRepresentation(title: "太阳"),
        .was: DisplayRepresentation(title: "奇才"),
        .nyk: DisplayRepresentation(title: "尼克斯"),
        .por: DisplayRepresentation(title: "开拓者"),
        .lac: DisplayRepresentation(title: "快船"),
        .den: DisplayRepresentation(title: "掘金"),
        .min: DisplayRepresentation(title: "森林狼"),
        .ind: DisplayRepresentation(title: "步行者"),
        .det: DisplayRepresentation(title: "活塞"),
        .lal: DisplayRepresentation(title: "湖人"),
        .hou: DisplayRepresentation(title: "火箭"),
        .mem: DisplayRepresentation(title: "灰熊"),
        .mia: DisplayRepresentation(title: "热火"),
        .uta: DisplayRepresentation(title: "爵士"),
        .dal: DisplayRepresentation(title: "独行侠"),
        .tor: DisplayRepresentation(title: "猛龙"),
        .bkn: DisplayRepresentation(title: "篮网"),
        .atl: DisplayRepresentation(title: "老鹰"),
        .mil: DisplayRepresentation(title: "雄鹿"),
        .okc: DisplayRepresentation(title: "雷霆"),
        .sas: DisplayRepresentation(title: "马刺"),
        .cle: DisplayRepresentation(title: "骑士"),
        .orl: DisplayRepresentation(title: "魔术"),
        .nop: DisplayRepresentation(title: "鹈鹕"),
        .cha: DisplayRepresentation(title: "黄蜂")
    ]
}

/// 长按小组件 →「编辑小组件」
struct ScheduleConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "NBA 赛程"
    static var description = IntentDescription("选择喜欢的球队，他们的比赛会置顶并高亮")

    @Parameter(title: "喜欢的球队")
    var teams: [TeamOption]?
}
