/* wasm_cairo.c -- pointer-last wrappers for Cairo entry points whose
 * native signature is (cairo_t *, double, double, ...).
 *
 * Chez Scheme's pb foreign-procedure ABI on tpb32l has a bug: when an
 * int/pointer argument precedes one or more double arguments, the
 * doubles arrive at the callee as zero. (Pure-pointer, pure-int, and
 * pure-double signatures all marshal correctly; (double..., int) at
 * the END also works.) Until that's fixed upstream in Chez/libffi
 * we route the affected Cairo entry points through these wrappers,
 * which take the same arguments in (doubles..., cairo_t *) order so
 * the marshaling path that actually works is used. The Racket side
 * declares foreign-procedure with the wrapped signature and the
 * call reaches Cairo correctly.
 *
 * Only entry points whose native signature begins with `cairo_t *`
 * followed by one or more doubles need wrapping. Functions like
 * `cairo_paint(cairo_t *)`, `cairo_create(cairo_surface_t *)`,
 * `cairo_image_surface_create(int, int, int)` are not affected.
 *
 * Registered via wasm_extras.inc; reachable from Racket through
 * (ffi/unsafe/vm)'s vm-eval + Chez foreign-procedure.
 */

#include <cairo.h>

/* Source */
void wasm_cairo_set_source_rgb(double r, double g, double b, cairo_t *cr) {
  cairo_set_source_rgb(cr, r, g, b);
}
void wasm_cairo_set_source_rgba(double r, double g, double b, double a, cairo_t *cr) {
  cairo_set_source_rgba(cr, r, g, b, a);
}

/* Path construction */
void wasm_cairo_move_to(double x, double y, cairo_t *cr) {
  cairo_move_to(cr, x, y);
}
void wasm_cairo_line_to(double x, double y, cairo_t *cr) {
  cairo_line_to(cr, x, y);
}
void wasm_cairo_rel_move_to(double dx, double dy, cairo_t *cr) {
  cairo_rel_move_to(cr, dx, dy);
}
void wasm_cairo_rel_line_to(double dx, double dy, cairo_t *cr) {
  cairo_rel_line_to(cr, dx, dy);
}
void wasm_cairo_rectangle(double x, double y, double w, double h, cairo_t *cr) {
  cairo_rectangle(cr, x, y, w, h);
}
void wasm_cairo_arc(double cx, double cy, double radius,
                    double angle1, double angle2, cairo_t *cr) {
  cairo_arc(cr, cx, cy, radius, angle1, angle2);
}
void wasm_cairo_arc_negative(double cx, double cy, double radius,
                             double angle1, double angle2, cairo_t *cr) {
  cairo_arc_negative(cr, cx, cy, radius, angle1, angle2);
}
void wasm_cairo_curve_to(double x1, double y1, double x2, double y2,
                         double x3, double y3, cairo_t *cr) {
  cairo_curve_to(cr, x1, y1, x2, y2, x3, y3);
}

/* Transforms */
void wasm_cairo_translate(double tx, double ty, cairo_t *cr) {
  cairo_translate(cr, tx, ty);
}
void wasm_cairo_scale(double sx, double sy, cairo_t *cr) {
  cairo_scale(cr, sx, sy);
}
void wasm_cairo_rotate(double angle, cairo_t *cr) {
  cairo_rotate(cr, angle);
}

/* Stroke + font */
void wasm_cairo_set_line_width(double w, cairo_t *cr) {
  cairo_set_line_width(cr, w);
}
void wasm_cairo_set_font_size(double size, cairo_t *cr) {
  cairo_set_font_size(cr, size);
}
