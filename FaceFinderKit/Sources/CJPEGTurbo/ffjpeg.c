#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>

#include "jpeglib.h"
#include "jerror.h"
#include "jconfigint.h"
#include "ffjpeg.h"

// libjpeg báo lỗi bằng cách gọi error_exit, mặc định là thoát chương trình. Ở đây nhảy về hàm gọi.
struct ff_error {
  struct jpeg_error_mgr pub;
  jmp_buf jump;
  int truncated;  /* gặp cuối file trước khi đủ dữ liệu ảnh (libjpeg tự chèn EOI giả) */
};

static void ff_error_exit(j_common_ptr cinfo) { longjmp(((struct ff_error *)cinfo->err)->jump, 1); }
static void ff_emit_message(j_common_ptr cinfo, int level)
{
  if (level < 0) {
    cinfo->err->num_warnings++;
    /* Pillow báo lỗi "image file is truncated" ở trường hợp này; làm giống vậy để CLI và app cùng coi là ảnh hỏng. */
    if (cinfo->err->msg_code == JWRN_JPEG_EOF) ((struct ff_error *)cinfo->err)->truncated = 1;
  }
}
static void ff_output_message(j_common_ptr cinfo) { (void)cinfo; }

// Đọc header và đặt thiết lập giải mã giống Pillow (JpegDecode.c với draft = 0).
static int ff_begin(struct jpeg_decompress_struct *cinfo, const unsigned char *data, size_t size, int scale_denom)
{
  if (scale_denom != 1 && scale_denom != 2 && scale_denom != 4 && scale_denom != 8) return FF_JPEG_ERROR;
  jpeg_mem_src(cinfo, data, (unsigned long)size);
  if (jpeg_read_header(cinfo, TRUE) != JPEG_HEADER_OK) return FF_JPEG_ERROR;
  if (cinfo->data_precision != 8 || cinfo->jpeg_color_space == JCS_CMYK || cinfo->jpeg_color_space == JCS_YCCK)
    return FF_JPEG_UNSUPPORTED;
  cinfo->out_color_space = JCS_EXT_BGRA;
  cinfo->scale_num = 1;
  cinfo->scale_denom = (unsigned int)scale_denom;
  return FF_JPEG_OK;
}

int ff_jpeg_output_size(const unsigned char *data, size_t size, int scale_denom, int *width, int *height)
{
  struct jpeg_decompress_struct cinfo;
  struct ff_error err;
  int rc;

  cinfo.err = jpeg_std_error(&err.pub);
  err.pub.error_exit = ff_error_exit;
  err.pub.emit_message = ff_emit_message;
  err.pub.output_message = ff_output_message;
  err.truncated = 0;
  if (setjmp(err.jump)) {
    jpeg_destroy_decompress(&cinfo);
    return FF_JPEG_ERROR;
  }
  jpeg_create_decompress(&cinfo);
  rc = ff_begin(&cinfo, data, size, scale_denom);
  if (rc == FF_JPEG_OK) {
    jpeg_calc_output_dimensions(&cinfo);
    *width = (int)cinfo.output_width;
    *height = (int)cinfo.output_height;
  }
  jpeg_destroy_decompress(&cinfo);
  return rc;
}

int ff_jpeg_decode_bgra(const unsigned char *data, size_t size, int scale_denom, unsigned char *out, size_t out_size)
{
  struct jpeg_decompress_struct cinfo;
  struct ff_error err;
  int rc;

  cinfo.err = jpeg_std_error(&err.pub);
  err.pub.error_exit = ff_error_exit;
  err.pub.emit_message = ff_emit_message;
  err.pub.output_message = ff_output_message;
  err.truncated = 0;
  if (setjmp(err.jump)) {
    jpeg_destroy_decompress(&cinfo);
    return FF_JPEG_ERROR;
  }
  jpeg_create_decompress(&cinfo);
  rc = ff_begin(&cinfo, data, size, scale_denom);
  if (rc == FF_JPEG_OK) {
    size_t stride;
    jpeg_start_decompress(&cinfo);
    stride = (size_t)cinfo.output_width * 4;
    if (cinfo.output_components != 4 || stride * cinfo.output_height > out_size) {
      rc = FF_JPEG_ERROR;
    } else {
      while (cinfo.output_scanline < cinfo.output_height) {
        JSAMPROW row = out + (size_t)cinfo.output_scanline * stride;
        jpeg_read_scanlines(&cinfo, &row, 1);
      }
      jpeg_finish_decompress(&cinfo);
      if (err.truncated) rc = FF_JPEG_TRUNCATED;
    }
  }
  jpeg_destroy_decompress(&cinfo);
  return rc;
}

const char *ff_jpeg_version(void) { return VERSION; }
