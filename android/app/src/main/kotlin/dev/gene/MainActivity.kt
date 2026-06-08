package dev.gene

import androidx.media3.common.util.UnstableApi
import dev.gene.editor.EditorApi
import dev.gene.editor.EditorApiImpl
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

@UnstableApi
class MainActivity : FlutterActivity() {
    private var editorApi: EditorApiImpl? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val impl = EditorApiImpl(this)
        editorApi = impl
        EditorApi.setUp(flutterEngine.dartExecutor.binaryMessenger, impl)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        editorApi?.dispose()
        editorApi = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
