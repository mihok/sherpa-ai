package io.github.mihok.sherpa_litert.lm

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.JsonPrimitive

/**
 * JSON ⇄ Kotlin values for tool-call arguments, with Gson (a LiteRT-LM dependency; pure JVM, so it also works in
 * unit tests, unlike `org.json`). Numbers stay `LazilyParsedNumber`s, so `1` round-trips as `1`, not `1.0`.
 */
object JsonValues {
  fun decodeObject(json: String): Map<String, Any?> {
    val e = JsonParser.parseString(json.ifBlank { "{}" })
    require(e.isJsonObject) { "tool-call arguments must be a JSON object" }
    @Suppress("UNCHECKED_CAST")
    return toKotlin(e) as Map<String, Any?>
  }

  fun encode(value: Any?): String = toJson(value).toString()

  fun toKotlin(e: JsonElement): Any? = when {
    e.isJsonNull -> null
    e.isJsonObject -> LinkedHashMap<String, Any?>().apply {
      for ((k, v) in e.asJsonObject.entrySet()) put(k, toKotlin(v))
    }
    e.isJsonArray -> e.asJsonArray.map { toKotlin(it) }
    else -> {
      val p = e.asJsonPrimitive
      when {
        p.isBoolean -> p.asBoolean
        p.isNumber -> p.asNumber
        else -> p.asString
      }
    }
  }

  fun toJson(value: Any?): JsonElement = when (value) {
    null -> JsonNull.INSTANCE
    is JsonElement -> value
    is Map<*, *> -> JsonObject().apply { for ((k, v) in value) add(k.toString(), toJson(v)) }
    is Iterable<*> -> JsonArray().apply { for (v in value) add(toJson(v)) }
    is Array<*> -> JsonArray().apply { for (v in value) add(toJson(v)) }
    is String -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    else -> JsonPrimitive(value.toString())
  }
}
