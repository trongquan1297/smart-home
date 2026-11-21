# Giữ lớp do Room sinh ra (WorkManager dùng Room): R8 của AGP 9.x xoá constructor không tham số của WorkDatabase_Impl
# vì nó chỉ được gọi qua reflection → app release crash ngay khi mở
# ("NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []").
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
