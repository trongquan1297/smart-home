-- Icon của phòng do người dùng chọn (living, bedroom, kitchen...). NULL = app tự gợi ý theo tên phòng.
ALTER TABLE rooms ADD COLUMN icon text;
