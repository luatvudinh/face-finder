// Lớp bọc mỏng quanh libjpeg-turbo cho Swift: giải mã JPEG 8 bit ra bitmap BGRA với đúng thiết lập mà Pillow dùng
// (IDCT chính xác JDCT_ISLOW, nội suy màu "fancy", thu nhỏ 1/1, 1/2, 1/4, 1/8 ngay trong bộ giải mã).
#ifndef FFJPEG_H
#define FFJPEG_H

#include <stddef.h>

#define FF_JPEG_OK 0
/// File hỏng hoặc không phải JPEG.
#define FF_JPEG_ERROR 1
/// JPEG hợp lệ nhưng thuộc loại lớp này không xử lý (CMYK/YCCK, 12/16 bit): để ImageIO đọc.
#define FF_JPEG_UNSUPPORTED 2

/// Kích thước ảnh sau khi giải mã ở tỉ lệ 1/scale_denom (scale_denom = 1, 2, 4 hoặc 8).
int ff_jpeg_output_size(const unsigned char *data, size_t size, int scale_denom, int *width, int *height);

/// Giải mã vào `out` (width * height * 4 byte, thứ tự B, G, R, A; A = 255). `out_size` phải đủ lớn.
int ff_jpeg_decode_bgra(const unsigned char *data, size_t size, int scale_denom, unsigned char *out, size_t out_size);

/// Chuỗi phiên bản libjpeg-turbo đang đóng gói.
const char *ff_jpeg_version(void);

#endif
