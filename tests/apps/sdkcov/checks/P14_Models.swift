// SDK coverage, round 18: [a] gaps needing a trained model. Models are trained with CreateML on a Mac and embedded
// compiled (.mlmodelc files, base64): watchOS cannot compile models on the device.
import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
#if canImport(CoreML)
import CoreML
#endif
#if canImport(SoundAnalysis)
import SoundAnalysis
import AVFoundation
#endif

/// a MaxEnt text classifier (CreateML MLTextClassifier, 6 sentences, labels pos / neg), compiled by coremlcompiler
private let p14SentimentModel: [(String, String)] = [
    ("metadata.json", "WwogIHsKICAgICJtZXRhZGF0YU91dHB1dFZlcnNpb24iIDogIjMuMCIsCiAgICAic2hvcnREZXNjcmlwdGlvbiIgOiAiVGhpcyBtb2RlbCBpcyBhIHRleHQgY2xhc3NpZmllciAodmVyc2lvbiAxKSB3aGljaCBjbGFzc2lmaWVzIHRleHQgYWNjb3JkaW5nIHRvIHNldCB7cG9zLG5lZ30iLAogICAgIm91dHB1dFNjaGVtYSIgOiBbCiAgICAgIHsKICAgICAgICAiaXNPcHRpb25hbCIgOiAiMCIsCiAgICAgICAgImZvcm1hdHRlZFR5cGUiIDogIlN0cmluZyIsCiAgICAgICAgInR5cGUiIDogIlN0cmluZyIsCiAgICAgICAgIm5hbWUiIDogImxhYmVsIiwKICAgICAgICAic2hvcnREZXNjcmlwdGlvbiIgOiAiVGV4dCBsYWJlbCIKICAgICAgfQogICAgXSwKICAgICJtb2RlbFBhcmFtZXRlcnMiIDogWwoKICAgIF0sCiAgICAic3BlY2lmaWNhdGlvblZlcnNpb24iIDogMywKICAgICJpc1VwZGF0YWJsZSIgOiAiMCIsCiAgICAic3RhdGVTY2hlbWEiIDogWwoKICAgIF0sCiAgICAiYXZhaWxhYmlsaXR5IiA6IHsKICAgICAgIm1hY09TIiA6ICIxMC4xNCIsCiAgICAgICJ0dk9TIiA6ICIxMi4wIiwKICAgICAgInZpc2lvbk9TIiA6ICIxLjAiLAogICAgICAid2F0Y2hPUyIgOiAiNS4wIiwKICAgICAgImlPUyIgOiAiMTIuMCIsCiAgICAgICJtYWNDYXRhbHlzdCIgOiAiMTIuMCIKICAgIH0sCiAgICAibW9kZWxUeXBlIiA6IHsKICAgICAgIm5hbWUiIDogIk1MTW9kZWxUeXBlX3RleHRDbGFzc2lmaWVyIgogICAgfSwKICAgICJpbnB1dFNjaGVtYSIgOiBbCiAgICAgIHsKICAgICAgICAiaXNPcHRpb25hbCIgOiAiMCIsCiAgICAgICAgImZvcm1hdHRlZFR5cGUiIDogIlN0cmluZyIsCiAgICAgICAgInR5cGUiIDogIlN0cmluZyIsCiAgICAgICAgIm5hbWUiIDogInRleHQiLAogICAgICAgICJzaG9ydERlc2NyaXB0aW9uIiA6ICJJbnB1dCB0ZXh0IgogICAgICB9CiAgICBdLAogICAgImNsYXNzTGFiZWxzIiA6IFsKICAgICAgInBvcyIsCiAgICAgICJuZWciCiAgICBdLAogICAgImdlbmVyYXRlZENsYXNzTmFtZSIgOiAic2VudGkiLAogICAgInVzZXJEZWZpbmVkTWV0YWRhdGEiIDogewoKICAgIH0sCiAgICAibWV0aG9kIiA6ICJwcmVkaWN0IgogIH0KXQ=="),
    ("coremldata.bin", "0AcAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAc3BlYwMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAMSkgEKFgoEdGV4dBIKSW5wdXQgdGV4dBoCGgBSFwoFbGFiZWwSClRleHQgbGFiZWwaAhoAogZeClxUaGlzIG1vZGVsIGlzIGEgdGV4dCBjbGFzc2lmaWVyICh2ZXJzaW9uIDEpIHdoaWNoIGNsYXNzaWZpZXMgdGV4dCBhY2NvcmRpbmcgdG8gc2V0IHtwb3MsbmVnfYJ9+wQIAaIG6ATe01YJBAAHAAEAAQAEAAAANAAAAHUAAACwAAAAuAAAAGgBAAAJAAAAeAEAAKIAAAAgAgAAQwAAAGJwbGlzdDAw0wECAwQFBllNb2RlbFR5cGVfEBlOdW1iZXJPZlRyYWluaW5nSW5zdGFuY2VzXUVtYmVkZGluZ1R5cGUQABAGVlN0YXRpYwgPGTVDRUcAAAAAAAABAQAAAAAAAAAHAAAAAAAAAAAAAAAAAAAATgAAABkAAAI+OHdeJQAAAj44d14iAAACPjh3XhcAAAE+PQqsIQAAAT49CqwbAAABPj0KrCYAAAI+OHdeHgAAAj44d14cAAACPjh3XhYAAAI+OHdeJAAAAj44d14VAAACPjh3XhMAAAI+OHdeEQAAAT44d14fAAACPjh3Xh0AAAE+OHdeIwAAAT44d14YAAACPjh3XhQAAAE+PQqsEgAAAT49CqwQAAABPmfSHRoAAAE+OHdeIAAAAT49CqwAcG9zAG5lZwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGdyZWF0AGF3ZXNvbWUAaGFwcHkAaGF0ZQBsb3ZlAHBvb3IAc2FkAG5pY2UAdGVycmlibGUAZHJlYWRmdWwAZ29vZABmdW4AYW5ncnkAam95AGJhZABwYWluAHdvbmRlcmZ1bABsb3ZlbHkAbWlzZXJhYmxlAGZhbnRhc3RpYwBhd2Z1bABjcnkAaG9ycmlibGUAAAAAAAAAYnBsaXN0MDCvEBEBAQEBAQEBAQEBAQEBAQEBAhAAEAIIHB4AAAAAAAABAQAAAAAAAAADAAAAAAAAAAAAAAAAAAAAIAAAAAAAwgwKCgNwb3MKA25lZw=="),
    ("analytics/coremldata.bin", "FAAAAAAAAABTcGVjaWZpY2F0aW9uRGV0YWlscwIAAAAAAAAACQAAAAAAAABtb2RlbEhhc2gsAAAAAAAAADdwV1dOWkhPTmVhamVub3BrWE0waklwSW8vU0ZxMmR3aW1LZGNyU1JVR3M9CQAAAAAAAABtb2RlbE5hbWUFAAAAAAAAAHNlbnRp")
]

/// a stateful ML program (coremltools 9 MIL builder, iOS 18 opset): y = acc + x, acc := y (a fp16 state of shape [1])
private let p14AccumulatorModel: [(String, String)] = [
    ("metadata.json", "WwogIHsKICAgICJtZXRhZGF0YU91dHB1dFZlcnNpb24iIDogIjMuMCIsCiAgICAib3V0cHV0U2NoZW1hIiA6IFsKICAgICAgewogICAgICAgICJoYXNTaGFwZUZsZXhpYmlsaXR5IiA6ICIwIiwKICAgICAgICAiaXNPcHRpb25hbCIgOiAiMCIsCiAgICAgICAgImRhdGFUeXBlIiA6ICJGbG9hdDE2IiwKICAgICAgICAiZm9ybWF0dGVkVHlwZSIgOiAiTXVsdGlBcnJheSAoRmxvYXQxNiAxKSIsCiAgICAgICAgInNob3J0RGVzY3JpcHRpb24iIDogIiIsCiAgICAgICAgInNoYXBlIiA6ICJbMV0iLAogICAgICAgICJuYW1lIiA6ICJ5IiwKICAgICAgICAidHlwZSIgOiAiTXVsdGlBcnJheSIKICAgICAgfQogICAgXSwKICAgICJtb2RlbFBhcmFtZXRlcnMiIDogWwoKICAgIF0sCiAgICAic3BlY2lmaWNhdGlvblZlcnNpb24iIDogOSwKICAgICJtbFByb2dyYW1PcGVyYXRpb25UeXBlSGlzdG9ncmFtIiA6IHsKICAgICAgIklvczE4LnJlYWRTdGF0ZSIgOiAyLAogICAgICAiSW9zMTguYWRkIiA6IDEsCiAgICAgICJJZGVudGl0eSIgOiAxLAogICAgICAiSW9zMTgud3JpdGVTdGF0ZSIgOiAxCiAgICB9LAogICAgImNvbXB1dGVQcmVjaXNpb24iIDogIkZsb2F0MTYiLAogICAgImlzVXBkYXRhYmxlIiA6ICIwIiwKICAgICJzdGF0ZVNjaGVtYSIgOiBbCiAgICAgIHsKICAgICAgICAiZGF0YVR5cGUiIDogIkZsb2F0MTYiLAogICAgICAgICJpc09wdGlvbmFsIiA6ICIwIiwKICAgICAgICAiZm9ybWF0dGVkVHlwZSIgOiAiU3RhdGUgKEZsb2F0MTYgMSkiLAogICAgICAgICJzaG9ydERlc2NyaXB0aW9uIiA6ICIiLAogICAgICAgICJzaGFwZSIgOiAiWzFdIiwKICAgICAgICAibmFtZSIgOiAiYWNjIiwKICAgICAgICAidHlwZSIgOiAiU3RhdGUiCiAgICAgIH0KICAgIF0sCiAgICAiYXZhaWxhYmlsaXR5IiA6IHsKICAgICAgIm1hY09TIiA6ICIxNS4wIiwKICAgICAgInR2T1MiIDogIjE4LjAiLAogICAgICAidmlzaW9uT1MiIDogIjIuMCIsCiAgICAgICJ3YXRjaE9TIiA6ICIxMS4wIiwKICAgICAgImlPUyIgOiAiMTguMCIsCiAgICAgICJtYWNDYXRhbHlzdCIgOiAiMTguMCIKICAgIH0sCiAgICAibW9kZWxUeXBlIiA6IHsKICAgICAgIm5hbWUiIDogIk1MTW9kZWxUeXBlX21sUHJvZ3JhbSIKICAgIH0sCiAgICAidXNlckRlZmluZWRNZXRhZGF0YSIgOiB7CiAgICAgICJjb20uZ2l0aHViLmFwcGxlLmNvcmVtbHRvb2xzLnZlcnNpb24iIDogIjkuMCIsCiAgICAgICJjb20uZ2l0aHViLmFwcGxlLmNvcmVtbHRvb2xzLmNvbnZlcnNpb25fZGF0ZSIgOiAiMjAyNi0xMS0xNyIsCiAgICAgICJjb20uZ2l0aHViLmFwcGxlLmNvcmVtbHRvb2xzLnNvdXJjZSIgOiAibWlsaW50ZXJuYWwiCiAgICB9LAogICAgImlucHV0U2NoZW1hIiA6IFsKICAgICAgewogICAgICAgICJoYXNTaGFwZUZsZXhpYmlsaXR5IiA6ICIwIiwKICAgICAgICAiaXNPcHRpb25hbCIgOiAiMCIsCiAgICAgICAgImRhdGFUeXBlIiA6ICJGbG9hdDE2IiwKICAgICAgICAiZm9ybWF0dGVkVHlwZSIgOiAiTXVsdGlBcnJheSAoRmxvYXQxNiAxKSIsCiAgICAgICAgInNob3J0RGVzY3JpcHRpb24iIDogIiIsCiAgICAgICAgInNoYXBlIiA6ICJbMV0iLAogICAgICAgICJuYW1lIiA6ICJ4IiwKICAgICAgICAidHlwZSIgOiAiTXVsdGlBcnJheSIKICAgICAgfQogICAgXSwKICAgICJnZW5lcmF0ZWRDbGFzc05hbWUiIDogImFjYyIsCiAgICAibWV0aG9kIiA6ICJwcmVkaWN0IgogIH0KXQ=="),
    ("model.mil", "cHJvZ3JhbSgxLjMpCltidWlsZEluZm8gPSBkaWN0PHN0cmluZywgc3RyaW5nPih7eyJjb3JlbWxjLWNvbXBvbmVudC1NSUwiLCAiMzYwNS4xLjEifSwgeyJjb3JlbWxjLXZlcnNpb24iLCAiMzYwMC4yNS4xIn0sIHsiY29yZW1sdG9vbHMtY29tcG9uZW50LW1pbGludGVybmFsIiwgIiJ9LCB7ImNvcmVtbHRvb2xzLXZlcnNpb24iLCAiOS4wIn19KV0KewogICAgZnVuYyBtYWluPGlvczE4PihzdGF0ZTx0ZW5zb3I8ZnAxNiwgWzFdPj4gYWNjLCB0ZW5zb3I8ZnAxNiwgWzFdPiB4KSB7CiAgICAgICAgICAgIHRlbnNvcjxmcDE2LCBbMV0+IHJlYWRfc3RhdGVfMCA9IHJlYWRfc3RhdGUoaW5wdXQgPSBhY2MpW25hbWUgPSBzdHJpbmcoInJlYWRfc3RhdGVfMCIpXTsKICAgICAgICAgICAgdGVuc29yPGZwMTYsIFsxXT4gYWRkXzAgPSBhZGQoeCA9IHJlYWRfc3RhdGVfMCwgeSA9IHgpW25hbWUgPSBzdHJpbmcoImFkZF8wIildOwogICAgICAgICAgICB3cml0ZV9zdGF0ZShkYXRhID0gYWRkXzAsIGlucHV0ID0gYWNjKVtuYW1lID0gc3RyaW5nKCJjb3JlbWxfdXBkYXRlX3N0YXRlXzFfd3JpdGVfc3RhdGUiKV07CiAgICAgICAgICAgIHRlbnNvcjxmcDE2LCBbMV0+IGNvcmVtbF91cGRhdGVfc3RhdGVfMSA9IHJlYWRfc3RhdGUoaW5wdXQgPSBhY2MpW25hbWUgPSBzdHJpbmcoImNvcmVtbF91cGRhdGVfc3RhdGVfMSIpXTsKICAgICAgICAgICAgdGVuc29yPGZwMTYsIFsxXT4geSA9IGlkZW50aXR5KHggPSBjb3JlbWxfdXBkYXRlX3N0YXRlXzEpW25hbWUgPSBzdHJpbmcoInkiKV07CiAgICAgICAgfSAtPiAoeSk7Cn0="),
    ("coremldata.bin", "9gEAAAkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAcAAAAAAAAAZ2VuZXJpYwkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA2AAAAAAAAAAKDgoBeBoJKgcKAQEQkIAEUg4KAXkaCSoHCgEBEJCABGoSCgNhY2MaC0IJCgcKAQEQkIAEogagAaIGKwokY29tLmdpdGh1Yi5hcHBsZS5jb3JlbWx0b29scy52ZXJzaW9uEgM5LjCiBjoKLGNvbS5naXRodWIuYXBwbGUuY29yZW1sdG9vbHMuY29udmVyc2lvbl9kYXRlEgoyMDI2LTExLTE3ogYyCiNjb20uZ2l0aHViLmFwcGxlLmNvcmVtbHRvb2xzLnNvdXJjZRILbWlsaW50ZXJuYWz2AQAAAAAAAAAAAAAAAAAA"),
    ("analytics/coremldata.bin", "GQAAAAAAAABOZXVyYWxOZXR3b3JrTW9kZWxEZXRhaWxzAgAAAAAAAAATAAAAAAAAAGNvbnRhaW5zQ3VzdG9tTGF5ZXIBAAAAAAAAADAOAAAAAAAAAG1vZGVsRGltZW5zaW9uAQAAAAAAAAAwFAAAAAAAAABTcGVjaWZpY2F0aW9uRGV0YWlscwIAAAAAAAAACQAAAAAAAABtb2RlbEhhc2gsAAAAAAAAAFZjNVJ4MFp5RVFLZkFJTWprR1ZQSU9qeXRWMUJIdHc2Y0h4VFVDazcxVUk9CQAAAAAAAABtb2RlbE5hbWUFAAAAAAAAAG1vZGVs")
]

/// a CreateML MLSoundClassifier (audio feature print + a logistic classifier) trained on 2 s 16 kHz clips: 6 sines
/// (300..800 Hz) labelled tone, 6 white noise clips labelled noise
private let p14SoundModel: [(String, String)] = [
    ("metadata.json", "WwogIHsKICAgICJzaG9ydERlc2NyaXB0aW9uIiA6ICJBIG1vZGVsIHRyYWluZWQgdXNpbmcgQ3JlYXRlTUwgZm9yIHVzZSB3aXRoIENvcmVNTC4iLAogICAgIm1ldGFkYXRhT3V0cHV0VmVyc2lvbiIgOiAiMy4wIiwKICAgICJvdXRwdXRTY2hlbWEiIDogWwogICAgICB7CiAgICAgICAgImlzT3B0aW9uYWwiIDogIjAiLAogICAgICAgICJmb3JtYXR0ZWRUeXBlIiA6ICJTdHJpbmciLAogICAgICAgICJ0eXBlIiA6ICJTdHJpbmciLAogICAgICAgICJuYW1lIiA6ICJ0YXJnZXQiLAogICAgICAgICJzaG9ydERlc2NyaXB0aW9uIiA6ICIiCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiaXNPcHRpb25hbCIgOiAiMCIsCiAgICAgICAgImtleVR5cGUiIDogIlN0cmluZyIsCiAgICAgICAgImZvcm1hdHRlZFR5cGUiIDogIkRpY3Rpb25hcnkgKFN0cmluZyDihpIgRG91YmxlKSIsCiAgICAgICAgInR5cGUiIDogIkRpY3Rpb25hcnkiLAogICAgICAgICJuYW1lIiA6ICJ0YXJnZXRQcm9iYWJpbGl0eSIsCiAgICAgICAgInNob3J0RGVzY3JpcHRpb24iIDogIiIKICAgICAgfQogICAgXSwKICAgICJ2ZXJzaW9uIiA6ICIxIiwKICAgICJtb2RlbFBhcmFtZXRlcnMiIDogWwoKICAgIF0sCiAgICAiYXV0aG9yIiA6ICJib2JieSIsCiAgICAic3BlY2lmaWNhdGlvblZlcnNpb24iIDogNiwKICAgICJzdGF0ZVNjaGVtYSIgOiBbCgogICAgXSwKICAgICJpc1VwZGF0YWJsZSIgOiAiMCIsCiAgICAiYXZhaWxhYmlsaXR5IiA6IHsKICAgICAgIm1hY09TIiA6ICIxMi4wIiwKICAgICAgInR2T1MiIDogIjE1LjAiLAogICAgICAidmlzaW9uT1MiIDogIjEuMCIsCiAgICAgICJ3YXRjaE9TIiA6ICI4LjAiLAogICAgICAiaU9TIiA6ICIxNS4wIiwKICAgICAgIm1hY0NhdGFseXN0IiA6ICIxNS4wIgogICAgfSwKICAgICJtb2RlbFR5cGUiIDogewogICAgICAibmFtZSIgOiAiTUxNb2RlbFR5cGVfcGlwZWxpbmVDbGFzc2lmaWVyIiwKICAgICAgInN0cnVjdHVyZSIgOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiIDogIk1MTW9kZWxUeXBlX2F1ZGlvRmVhdHVyZVByaW50IgogICAgICAgIH0sCiAgICAgICAgewogICAgICAgICAgIm5hbWUiIDogIk1MTW9kZWxUeXBlX2dsbUNsYXNzaWZpZXIiCiAgICAgICAgfQogICAgICBdCiAgICB9LAogICAgImlucHV0U2NoZW1hIiA6IFsKICAgICAgewogICAgICAgICJkYXRhVHlwZSIgOiAiRmxvYXQzMiIsCiAgICAgICAgImhhc1NoYXBlRmxleGliaWxpdHkiIDogIjEiLAogICAgICAgICJpc09wdGlvbmFsIiA6ICIwIiwKICAgICAgICAic2hhcGVGbGV4aWJpbGl0eSIgOiAiODAwMC4uLjI0MDAwMCIsCiAgICAgICAgInNoYXBlUmFuZ2UiIDogIltbODAwMCwgMjQwMDAwXV0iLAogICAgICAgICJmb3JtYXR0ZWRUeXBlIiA6ICJNdWx0aUFycmF5IChGbG9hdDMyIDE1NjAwKSIsCiAgICAgICAgInR5cGUiIDogIk11bHRpQXJyYXkiLAogICAgICAgICJzaGFwZSIgOiAiWzE1NjAwXSIsCiAgICAgICAgIm5hbWUiIDogImF1ZGlvU2FtcGxlcyIsCiAgICAgICAgInNob3J0RGVzY3JpcHRpb24iIDogIiIKICAgICAgfQogICAgXSwKICAgICJjbGFzc0xhYmVscyIgOiBbCiAgICAgICJub2lzZSIsCiAgICAgICJ0b25lIgogICAgXSwKICAgICJnZW5lcmF0ZWRDbGFzc05hbWUiIDogInNuZCIsCiAgICAidXNlckRlZmluZWRNZXRhZGF0YSIgOiB7CiAgICAgICJzYW1wbGVSYXRlIiA6ICIxNjAwMCIsCiAgICAgICJjb20uYXBwbGUuY3JlYXRlbWwudmVyc2lvbiIgOiAiMjcuMC4wIgogICAgfSwKICAgICJtZXRob2QiIDogInByZWRpY3QiCiAgfQpd"),
    ("model0/coremldata.bin", "1gcAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAc3BlYwYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAYSgAEKJgoMYXVkaW9TYW1wbGVzGhYqFAoC8HkQoIAE+gEJCgcIwD4QgNMOUhYKCGZlYXR1cmVzGgoqCAoCgAQQoIAEogY9ogYTCgpzYW1wbGVSYXRlEgUxNjAwMKIGJAoaY29tLmFwcGxlLmNyZWF0ZW1sLnZlcnNpb24SBjI3LjAuMLJ9BaIBAggB"),
    ("model1/coremldata.bin", "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"),
    ("coremldata.bin", "yAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAACkAAAAAAAAAZ2VuZXJpYy5tb2RlbDB2MS4wLjBzcGVjLm1vZGVsMXYxLjAuMHNwZWMGAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAOsAAAAAAAAACiYKDGF1ZGlvU2FtcGxlcxoWKhQKAvB5EKCABPoBCQoHCMA+EIDTDlIMCgZ0YXJnZXQaAhoAUhkKEXRhcmdldFByb2JhYmlsaXR5GgQyAhIAWgZ0YXJnZXRiEXRhcmdldFByb2JhYmlsaXR5ogZ8CjNBIG1vZGVsIHRyYWluZWQgdXNpbmcgQ3JlYXRlTUwgZm9yIHVzZSB3aXRoIENvcmVNTC4SATEaBWJvYmJ5ogYTCgpzYW1wbGVSYXRlEgUxNjAwMKIGJAoaY29tLmFwcGxlLmNyZWF0ZW1sLnZlcnNpb24SBjI3LjAuMAIAAAAAAAAAyAAAAAAAAAA="),
    ("analytics/coremldata.bin", "FAAAAAAAAABQaXBlbGluZU1vZGVsRGV0YWlscwEAAAAAAAAADgAAAAAAAABtb2RlbERpbWVuc2lvbgEAAAAAAAAAMhQAAAAAAAAAU3BlY2lmaWNhdGlvbkRldGFpbHMCAAAAAAAAAAkAAAAAAAAAbW9kZWxIYXNoLAAAAAAAAABFdTFRcjJXZ2NoRm9EY1VtcE9Oa09MSm12MFRtWlh4Y0RxLy9IbzhsU0xVPQkAAAAAAAAAbW9kZWxOYW1lAwAAAAAAAABzbmQ=")
]

/// write an embedded .mlmodelc into tmp and return its URL
func p14WriteModel(_ name: String, _ files: [(String, String)]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("p14-\(name).mlmodelc", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    for (p, b) in files {
        let u = dir.appendingPathComponent(p)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = Data(base64Encoded: b) else { throw Fail("bad base64 for \(p)") }
        try d.write(to: u)
    }
    return dir
}

extension Registry {
    static var p14_models: [Check] {
        var c: [Check] = []
        #if canImport(NaturalLanguage) && canImport(CoreML)
        // MARK: NaturalLanguage: NLModel from a compiled CreateML text classifier (predictedLabel, label hypotheses)
        c.append(check("NaturalLanguage", "nlmodel-custom-text-classifier", timeout: 60) {
            let url = try p14WriteModel("senti", p14SentimentModel)
            let ml = try MLModel(contentsOf: url)
            let nl = try NLModel(mlModel: ml)
            let nl2 = try NLModel(contentsOf: url)
            let a = nl.predictedLabel(for: "what a wonderful happy day") ?? "nil"
            let b = nl2.predictedLabel(for: "this is awful and sad") ?? "nil"
            let h = nl.predictedLabelHypotheses(for: "great fun", maximumCount: 2)
            try expect(a == "pos" && b == "neg", "predicted \(a) / \(b) (want pos / neg)")
            try expect(Set(h.keys) == ["pos", "neg"] && (h["pos"] ?? 0) > (h["neg"] ?? 1), "hypotheses \(h)")
            try expect(nl.configuration.type == .classifier, "model type \(nl.configuration.type.rawValue)")
            let hs = h.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.2f", $0.value))" }
            return "pos / neg predicted, hypotheses \(hs), revision \(nl.configuration.revision)"
        })
        #endif
        #if canImport(CoreML)
        // MARK: CoreML: a stateful model: makeState, predictions through a state accumulate, a fresh state starts at 0
        c.append(check("CoreML", "mlstate-stateful-prediction", timeout: 60) {
            let url = try p14WriteModel("acc", p14AccumulatorModel)
            let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuOnly
            let m = try MLModel(contentsOf: url, configuration: cfg)
            let states = m.modelDescription.stateDescriptionsByName.keys.sorted()
            try expect(states == ["acc"], "state descriptions \(states)")
            func run(_ st: MLState, _ v: Float) async throws -> Float {
                let x = try MLMultiArray(shape: [1], dataType: .float16); x[0] = NSNumber(value: v)
                let out = try await m.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["x": x]), using: st)
                guard let y = out.featureValue(for: "y")?.multiArrayValue else { throw Fail("no y in \(out.featureNames)") }
                return y[0].floatValue
            }
            let s1 = m.makeState()
            var ys: [Float] = []
            for v: Float in [1, 2, 3] { ys.append(try await run(s1, v)) }
            let s2 = m.makeState()
            // a new state's buffer is not defined until written: zero it through withMultiArray
            s2.withMultiArray(for: "acc") { a in a[0] = 0 }
            let fresh = try await run(s2, 5)
            var kept: Float = -1
            s1.withMultiArray(for: "acc") { a in kept = a[0].floatValue }
            try expect(ys.suffix(2) == [ys[0] + 2, ys[0] + 5] && fresh == 5 && kept == ys[2], "outputs \(ys), fresh state \(fresh), state 1 holds \(kept)")
            return "states \(states); one state accumulates \(ys), a zeroed second state answers \(fresh), state 1 reads \(kept)"
        })
        #endif
        #if canImport(SoundAnalysis) && canImport(CoreML)
        // MARK: SoundAnalysis: SNClassifySoundRequest(mlModel:) with a custom classifier: a sine is "tone", noise "noise"
        c.append(check("SoundAnalysis", "custom-mlmodel-classifier", timeout: 90) {
            let m = try MLModel(contentsOf: try p14WriteModel("snd", p14SoundModel))
            func classify(_ noise: Bool) throws -> (String, Double, [String]) {
                let req = try SNClassifySoundRequest(mlModel: m)
                let fmt = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                let n = AVAudioFrameCount(16000 * 3)
                let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!; b.frameLength = n
                var g = SystemRandomNumberGenerator()
                for i in 0..<Int(n) { b.floatChannelData![0][i] = noise ? Float.random(in: -0.37...0.37, using: &g) : 0.37 * sin(2 * .pi * 550 * Float(i) / 16000) }
                final class O: NSObject, SNResultsObserving { var tops: [(String, Double)] = []
                    func request(_ r: SNRequest, didProduce res: SNResult) { if let c = res as? SNClassificationResult, let f = c.classifications.first { tops.append((f.identifier, f.confidence)) } } }
                let an = SNAudioStreamAnalyzer(format: fmt); let o = O()
                try an.add(req, withObserver: o)
                an.analyze(b, atAudioFramePosition: 0); an.completeAnalysis()
                guard let t = o.tops.first else { throw Fail("no classification (\(noise ? "noise" : "tone"))") }
                return (t.0, t.1, req.knownClassifications.sorted())
            }
            let (a, ca, known) = try classify(false), (b, cb, _) = try classify(true)
            try expect(known == ["noise", "tone"], "known classifications \(known)")
            try expect(a == "tone" && b == "noise", "a sine classified \(a) (\(ca)), noise \(b) (\(cb))")
            return "classes \(known): sine -> \(a) \(String(format: "%.2f", ca)), noise -> \(b) \(String(format: "%.2f", cb))"
        })
        #endif
        return c
    }
}
