import Metal
import MetalPerformanceShaders

/// гауссово размытие кадра; при `downsample` больше 1 считается на уменьшенной копии
@MainActor final class GaussianPass {
    /// размытие слабее этого не видно, отдаём исходник
    static let invisibleSigma: Float = 0.25

    private let device: any MTLDevice
    private let downsample: Int
    private let downscaler: MPSImageBilinearScale
    private var reduced: (any MTLTexture)?
    private var output: (any MTLTexture)?
    private var kernel: (filter: MPSImageGaussianBlur, sigma: Float)?
    private var cached: (source: ObjectIdentifier, number: UInt64, sigma: Float, command: any MTLCommandBuffer)?
    private(set) var encodedPasses = 0

    init(device: any MTLDevice, downsample: Int) {
        self.device = device
        self.downsample = downsample
        downscaler = MPSImageBilinearScale(device: device)
    }

    /// кеширует размытие по версии `sourceNumber`; без версии считает заново
    func blurred(_ source: any MTLTexture, sigma: Float, sourceNumber: UInt64?,
                 into command: any MTLCommandBuffer) -> (any MTLTexture)? {
        let scaledSigma = sigma / Float(downsample)
        guard scaledSigma >= Self.invisibleSigma else { return source }
        if let output, let cached, let sourceNumber, cached.number == sourceNumber,
           cached.source == ObjectIdentifier(source), cached.sigma == scaledSigma,
           [.committed, .scheduled, .completed].contains(cached.command.status) {
            return output
        }
        guard let output = prepareOutput(width: source.width / downsample, height: source.height / downsample) else {
            return nil
        }
        let filter = gaussian(sigma: scaledSigma)
        if downsample > 1 {
            guard let reduced else { return nil }
            downscaler.encode(commandBuffer: command, sourceTexture: source, destinationTexture: reduced)
            filter.encode(commandBuffer: command, sourceTexture: reduced, destinationTexture: output)
        } else {
            filter.encode(commandBuffer: command, sourceTexture: source, destinationTexture: output)
        }
        encodedPasses += 1
        cached = sourceNumber.map { (ObjectIdentifier(source), $0, scaledSigma, command) }
        return output
    }

    /// кадр не ушёл на GPU: закешированный результат недействителен
    func forgetCached() {
        cached = nil
    }

    func reset() {
        reduced = nil
        output = nil
        kernel = nil
        cached = nil
    }

    private func prepareOutput(width: Int, height: Int) -> (any MTLTexture)? {
        let width = max(1, width)
        let height = max(1, height)
        if let output, output.width == width, output.height == height { return output }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        output = device.makeTexture(descriptor: descriptor)
        reduced = downsample > 1 ? device.makeTexture(descriptor: descriptor) : nil
        cached = nil
        return output
    }

    private func gaussian(sigma: Float) -> MPSImageGaussianBlur {
        if let kernel, kernel.sigma == sigma { return kernel.filter }
        let filter = MPSImageGaussianBlur(device: device, sigma: sigma)
        filter.edgeMode = .clamp
        kernel = (filter, sigma)
        return filter
    }
}
