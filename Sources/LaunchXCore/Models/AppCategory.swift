import Foundation

/// 应用分类词典（原版内置分类，用于排序与整理规则）。
public enum AppCategory {

    /// LSApplicationCategoryType → 本地化名。
    public static let known: [String: String] = [
        "public.app-category.business": "商务",
        "public.app-category.developer-tools": "开发者工具",
        "public.app-category.education": "教育",
        "public.app-category.entertainment": "娱乐",
        "public.app-category.finance": "财务",
        "public.app-category.food-and-drink": "美食佳饮",
        "public.app-category.games": "游戏",
        "public.app-category.graphics-design": "图形与设计",
        "public.app-category.healthcare-fitness": "健康与健身",
        "public.app-category.lifestyle": "生活",
        "public.app-category.medical": "医疗",
        "public.app-category.music": "音乐",
        "public.app-category.news": "新闻",
        "public.app-category.photography": "摄影",
        "public.app-category.productivity": "效率",
        "public.app-category.reference": "参考",
        "public.app-category.social-networking": "社交",
        "public.app-category.sports": "体育",
        "public.app-category.travel": "旅行",
        "public.app-category.utilities": "实用工具",
        "public.app-category.video": "视频",
        "public.app-category.weather": "天气",
        "public.app-category.books": "图书",
    ]

    /// 全部分类名（含「其他」），排序展示用。
    public static let allNames: [String] = Array(known.values).sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    /// 原始 category 值 → 本地化名；未知或空归「其他」。
    public static func displayName(for raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "其他" }
        return known[raw] ?? "其他"
    }

    /// 是否 Apple 官方应用（bundleId 前缀判断）。
    public static func isAppleApp(bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return bundleId.hasPrefix("com.apple.")
    }
}
