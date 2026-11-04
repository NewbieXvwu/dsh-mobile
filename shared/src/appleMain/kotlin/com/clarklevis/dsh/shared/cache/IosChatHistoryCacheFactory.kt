package com.clarklevis.dsh.shared.cache

import androidx.room.Room
import kotlinx.cinterop.ExperimentalForeignApi
import platform.Foundation.NSFileManager
import platform.Foundation.NSFileSystemFreeSize
import platform.Foundation.NSLog
import platform.Foundation.NSNumber

class IosChatHistoryCacheFactory {
    @OptIn(ExperimentalForeignApi::class)
    @Throws(Exception::class)
    fun create(path: String, maximumBytes: Long, targetBytes: Long): SharedChatHistoryCache =
        Room.databaseBuilder<ChatCacheDatabase>(name = path)
            .buildCache(maximumBytes, targetBytes) {
                runCatching {
                    val directory = path.substringBeforeLast('/', "/")
                    val attributes = NSFileManager.defaultManager.attributesOfFileSystemForPath(directory, null)
                    (attributes?.get(NSFileSystemFreeSize) as? NSNumber)?.longLongValue
                }.getOrNull()
            }
}

@OptIn(ExperimentalForeignApi::class)
internal actual fun writeChatCacheLog(message: String, warning: Boolean) {
    val text = if (warning) "$message level=warning" else message
    // 避免可变参数跨 Kotlin/Objective-C 边界；转义格式字符后仅传入 format。
    NSLog(text.replace("%", "%%"))
}
