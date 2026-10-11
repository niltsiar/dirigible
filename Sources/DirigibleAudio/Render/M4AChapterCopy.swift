import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import ImageIO

/// The longest title in a chapter sample: its length field has 16 bits and counts UTF-8 bytes.
let maximumChapterTitleBytes = 65_535

/// The valid frames of the AAC file `url` (no priming and no remainder), from its packet table.
func validFrames(_ url: URL) throws(ExportError) -> Int {
    var opened: AudioFileID?
    var result = AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileM4AType, &opened)
    guard result == noErr, let file = opened else { throw .writeFailed(result) }
    defer { AudioFileClose(file) }
    var info = AudioFilePacketTableInfo()
    var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
    result = AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &info)
    guard result == noErr else { throw .writeFailed(result) }
    return Int(info.mNumberValidFrames)
}

/// Copies the AAC file `source` to `output` with an `AVAssetWriter` and adds a disabled `tx3g`
/// chapter track and, with `images`, a JPEG chapter image track. Both are chapter lists of the audio
/// track (probe P1, recipe a). The movie and each chapter track have the time scale `rate`, so the
/// frame count and `iTunSMPB` stay. Each chapter sample lasts to the next start; the last one ends
/// at `frames`. One loop on the calling thread owns the writer: it appends each chapter sample
/// before the audio, and it reads `isCancelled()` before each sample, each audio buffer, and every
/// 50 ms of the finish. A cancel or a failure leaves `output` to the caller, which removes it.
func copyWithChapters(
    _ source: URL, items: [AVMetadataItem], chapters: [ExportChapter], images: [(start: Int, jpeg: Data)],
    rate: Int, frames: Int, to output: URL, isCancelled: () -> Bool
) throws(ExportError) {
    // A `.tmp` name gives -11800 with no MIME type (probe U17).
    let asset = AVURLAsset(url: source, options: [AVURLAssetOverrideMIMETypeKey: "audio/mp4"])
    let track = try audioTrack(of: asset, isCancelled: isCancelled)
    let reader: AVAssetReader
    let writer: AVAssetWriter
    do {
        reader = try AVAssetReader(asset: asset)
        writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
    } catch { throw .writeFailed(status(of: error)) }
    let audioOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(audioOutput)
    // The first buffer gives the format hint of the passthrough input.
    guard reader.startReading(), var next = audioOutput.copyNextSampleBuffer(),
        let audioFormat = CMSampleBufferGetFormatDescription(next)
    else { throw .writeFailed(status(of: reader.error)) }
    let scale = CMTimeScale(rate)
    writer.movieTimeScale = scale
    writer.metadata = items
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
    audioInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(audioInput) else { throw .writeFailed(kAudio_ParamError) }
    writer.add(audioInput)

    let time = { (frame: Int) in CMTime(value: CMTimeValue(frame), timescale: scale) }
    // Each sample is made in the append loop, so the loop reads the cancel between two samples.
    let textFormat = try chapterTextFormat()
    let titles = zip(chapters, chapters.dropFirst().map(\.start) + [frames]).map {
        (data: textSample($0.title), start: $0.start, end: $1)
    }
    var queues = [
        (try chapterInput(.text, hint: textFormat, scale: scale, writer: writer, audio: audioInput), titles)
    ]
    if let first = images.first {
        let samples = zip(images, images.dropFirst().map(\.start) + [frames]).map {
            (data: $0.jpeg, start: $0.start, end: $1)
        }
        let hint = try jpegFormat(first.jpeg)
        queues.append((try chapterInput(.video, hint: hint, scale: scale, writer: writer, audio: audioInput), samples))
    }

    guard writer.startWriting() else { throw .writeFailed(status(of: writer.error)) }
    writer.startSession(atSourceTime: .zero)
    /// Appends `buffer` when `input` is ready, with a cancel read before each try.
    func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput) throws(ExportError) {
        while true {
            if isCancelled() { throw .cancelled }
            if writer.status == .failed { throw .writeFailed(status(of: writer.error)) }
            if input.isReadyForMoreMediaData { break }
            usleep(500)
        }
        guard input.append(buffer) else { throw .writeFailed(status(of: writer.error)) }
    }
    do throws(ExportError) {
        // The chapter tracks go before the audio data (`.beforeMainMediaDataNotInterleaved`).
        for (input, samples) in queues {
            for sample in samples {
                let format = input.mediaType == .text ? textFormat : try jpegFormat(sample.data)
                let buffer = try sampleBuffer(
                    sample.data, format: format, start: time(sample.start), end: time(sample.end))
                try append(buffer, to: input)
            }
            input.markAsFinished()
        }
        while true {
            try append(next, to: audioInput)
            guard let buffer = audioOutput.copyNextSampleBuffer() else { break }
            next = buffer
        }
        guard reader.status == .completed else { throw .writeFailed(status(of: reader.error)) }
    } catch {
        reader.cancelReading()
        writer.cancelWriting()
        throw error
    }
    audioInput.markAsFinished()
    try waitCancellable(isCancelled: isCancelled, cancel: {}, start: { done in writer.finishWriting { done.signal() } })
    guard writer.status == .completed else { throw .writeFailed(status(of: writer.error)) }
}

/// The audio track of `asset`. The wait reads `isCancelled()` every 50 ms and stops after 10 s, so a
/// load that never ends does not hang the export.
private func audioTrack(of asset: AVURLAsset, isCancelled: () -> Bool) throws(ExportError) -> AVAssetTrack {
    nonisolated(unsafe) var found: AVAssetTrack?
    let done = DispatchSemaphore(value: 0)
    asset.loadTracks(withMediaType: .audio) { tracks, _ in
        found = tracks?.first
        done.signal()
    }
    var waits = 0
    while done.wait(timeout: .now() + 0.05) == .timedOut {
        if isCancelled() { throw .cancelled }
        waits += 1
        if waits == 200 { throw .writeFailed(kAudio_FileNotFoundError) }
    }
    guard let track = found else { throw .writeFailed(kAudio_FileNotFoundError) }
    return track
}

/// A disabled chapter input of the writer with the time scale `scale`, added as a chapter list of
/// `audio`.
private func chapterInput(
    _ type: AVMediaType, hint: CMFormatDescription, scale: CMTimeScale, writer: AVAssetWriter,
    audio: AVAssetWriterInput
) throws(ExportError) -> AVAssetWriterInput {
    let input = AVAssetWriterInput(mediaType: type, outputSettings: nil, sourceFormatHint: hint)
    input.expectsMediaDataInRealTime = false
    input.marksOutputTrackAsEnabled = false
    input.mediaTimeScale = scale
    input.languageCode = "eng"
    input.extendedLanguageTag = "en"
    input.mediaDataLocation = .beforeMainMediaDataNotInterleaved
    let chapterList = AVAssetTrack.AssociationType.chapterList.rawValue
    guard writer.canAdd(input) else { throw .writeFailed(kAudio_ParamError) }
    writer.add(input)
    guard audio.canAddTrackAssociation(withTrackOf: input, type: chapterList) else {
        throw .writeFailed(kAudio_ParamError)
    }
    audio.addTrackAssociation(withTrackOf: input, type: chapterList)
    return input
}

/// A `tx3g` sample: a 16-bit big-endian length and the UTF-8 title, cut at a character boundary to
/// `maximumChapterTitleBytes`.
func textSample(_ title: String) -> Data {
    var bytes = 0
    var end = title.startIndex
    for index in title.indices {
        let count = title[index].utf8.count
        guard bytes + count <= maximumChapterTitleBytes else { break }
        bytes += count
        end = title.index(after: index)
    }
    let length = UInt16(bytes)
    return Data([UInt8(length >> 8), UInt8(length & 0xFF)]) + Data(title[..<end].utf8)
}

/// The `tx3g` format of the chapter track: black text, no box, the font Sans-Serif.
private func chapterTextFormat() throws(ExportError) -> CMFormatDescription {
    let black: [CFString: Any] = [
        kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
        kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 255,
    ]
    let extensions: [CFString: Any] = [
        kCMTextFormatDescriptionExtension_DisplayFlags: 0,
        kCMTextFormatDescriptionExtension_BackgroundColor: black,
        kCMTextFormatDescriptionExtension_DefaultTextBox: [
            kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
            kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
        ],
        kCMTextFormatDescriptionExtension_DefaultStyle: [
            kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
            kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
            kCMTextFormatDescriptionStyle_ForegroundColor: black, kCMTextFormatDescriptionStyle_FontSize: 12,
        ],
        kCMTextFormatDescriptionExtension_HorizontalJustification: 0,
        kCMTextFormatDescriptionExtension_VerticalJustification: 0,
        kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
    ]
    var format: CMFormatDescription?
    let result = CMFormatDescriptionCreate(
        allocator: nil, mediaType: kCMMediaType_Text, mediaSubType: kCMTextFormatType_3GText,
        extensions: extensions as CFDictionary, formatDescriptionOut: &format)
    guard result == noErr, let format else { throw .writeFailed(result) }
    return format
}

/// The video format of a JPEG, with its pixel size.
private func jpegFormat(_ jpeg: Data) throws(ExportError) -> CMFormatDescription {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int32,
        let height = properties[kCGImagePropertyPixelHeight] as? Int32
    else { throw .writeFailed(kAudio_ParamError) }
    var format: CMFormatDescription?
    let result = CMVideoFormatDescriptionCreate(
        allocator: nil, codecType: kCMVideoCodecType_JPEG, width: width, height: height, extensions: nil,
        formatDescriptionOut: &format)
    guard result == noErr, let format else { throw .writeFailed(result) }
    return format
}

/// One sample of `data` from `start` to `end`.
private func sampleBuffer(
    _ data: Data, format: CMFormatDescription, start: CMTime, end: CMTime
) throws(ExportError) -> CMSampleBuffer {
    var block: CMBlockBuffer?
    var result = CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
        offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    guard result == noErr, let block else { throw .writeFailed(result) }
    result = data.withUnsafeBytes { raw in
        CMBlockBufferReplaceDataBytes(
            with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
    }
    guard result == noErr else { throw .writeFailed(result) }
    var timing = CMSampleTimingInfo(duration: end - start, presentationTimeStamp: start, decodeTimeStamp: .invalid)
    var size = data.count
    var buffer: CMSampleBuffer?
    result = CMSampleBufferCreateReady(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
    guard result == noErr, let buffer else { throw .writeFailed(result) }
    return buffer
}
