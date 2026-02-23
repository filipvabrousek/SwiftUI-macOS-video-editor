import Foundation

enum VideoFilter: String, CaseIterable, Identifiable, Equatable, Sendable {
    case none
    case sepia
    case grayscale
    case vignette
    case bloom
    case gaussianBlur
    case sharpen
    case colorInvert

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:         return "None"
        case .sepia:        return "Sepia"
        case .grayscale:    return "Grayscale"
        case .vignette:     return "Vignette"
        case .bloom:        return "Bloom"
        case .gaussianBlur: return "Gaussian Blur"
        case .sharpen:      return "Sharpen"
        case .colorInvert:  return "Invert Colors"
        }
    }

    var ciFilterName: String? {
        switch self {
        case .none:         return nil
        case .sepia:        return "CISepiaTone"
        case .grayscale:    return "CIPhotoEffectMono"
        case .vignette:     return "CIVignette"
        case .bloom:        return "CIBloom"
        case .gaussianBlur: return "CIGaussianBlur"
        case .sharpen:      return "CISharpenLuminance"
        case .colorInvert:  return "CIColorInvert"
        }
    }

    var systemImage: String {
        switch self {
        case .none:         return "circle.slash"
        case .sepia:        return "photo.artframe"
        case .grayscale:    return "circle.lefthalf.filled"
        case .vignette:     return "circle.dashed"
        case .bloom:        return "sparkles"
        case .gaussianBlur: return "aqi.medium"
        case .sharpen:      return "triangle"
        case .colorInvert:  return "circle.lefthalf.striped.horizontal.inverse"
        }
    }
}
