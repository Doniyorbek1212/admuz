package uz.sado.app

import android.content.Context
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Round video messages must be square or Telegram delivers them as ordinary videos. The camera
 * records a rectangular frame, so this re-encodes it center-cropped to size×size (H.264 + AAC).
 */
object VideoNoteTranscoder {
    const val CHANNEL = "uz.sado.app/video"

    /** Must run on a looper thread (the method channel's main thread); answers [result] when done. */
    @OptIn(UnstableApi::class)
    fun cropSquare(context: Context, input: String, output: String, size: Int, result: MethodChannel.Result) {
        val transformer = Transformer.Builder(context)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    result.success(output)
                }

                override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                    File(output).delete()
                    result.error("transcode_failed", exportException.message, null)
                }
            })
            .build()
        val crop = Presentation.createForWidthAndHeight(size, size, Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP)
        val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(input))))
            .setEffects(Effects(emptyList(), listOf(crop)))
            .build()
        transformer.start(item, output)
    }
}
