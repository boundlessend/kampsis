import Metal
import MetalKit

enum RenderSetupFailure: LocalizedError {
    case noMetalDevice
    case noCommandQueue
    case missingShaderFunction(String)

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: "Metal недоступен на этом Mac."
        case .noCommandQueue: "Не удалось создать очередь команд Metal."
        case let .missingShaderFunction(name): "В шейдере эффекта нет функции \(name)."
        }
    }
}

/// общий для всего приложения набор Metal: устройство, очередь, конвейеры и картинка превью
@MainActor final class MetalStack {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let backdrop: any MTLRenderPipelineState
    let sheet: any MTLRenderPipelineState
    let sampleDesktop: any MTLTexture

    static let pixelFormat = MTLPixelFormat.bgra8Unorm_srgb

    static let shared: Result<MetalStack, any Error> = Result { try MetalStack() }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderSetupFailure.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw RenderSetupFailure.noCommandQueue }
        let library = try device.makeLibrary(source: foldShaderSource, options: nil)
        self.device = device
        self.queue = queue
        backdrop = try Self.pipeline(device, library, vertex: "backdropVertex", fragment: "backdropFragment")
        sheet = try Self.pipeline(device, library, vertex: "sheetVertex", fragment: "sheetFragment")
        sampleDesktop = try MTKTextureLoader(device: device).newTexture(
            cgImage: drawSampleDesktop(),
            options: [.SRGB: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue]
        )
    }

    /// премультиплицированная альфа: оверлей прозрачен там, где эффект ещё не закрыл экран
    private static func pipeline(_ device: any MTLDevice, _ library: any MTLLibrary,
                                 vertex: String, fragment: String) throws -> any MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: vertex) else {
            throw RenderSetupFailure.missingShaderFunction(vertex)
        }
        guard let fragmentFunction = library.makeFunction(name: fragment) else {
            throw RenderSetupFailure.missingShaderFunction(fragment)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        let target = descriptor.colorAttachments[0]
        target?.pixelFormat = pixelFormat
        target?.isBlendingEnabled = true
        target?.sourceRGBBlendFactor = .one
        target?.sourceAlphaBlendFactor = .one
        target?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        target?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
