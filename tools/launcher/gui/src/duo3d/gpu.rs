//! Draws the mesh with OpenGL inside egui (an egui_glow paint callback): into a framebuffer of its own at twice the
//! area's pixels with a depth buffer, then that image shrunk into the area (2x2 supersampling: smooth edges and
//! steady screen pictures), over egui's own drawing with premultiplied alpha.
use super::mesh::{Mesh, Vtx};
use eframe::{egui, egui_glow};
use eframe::glow::{self, HasContext};
use std::sync::{Arc, Mutex};

/// What a frame draws: the mesh, the camera (view rotation, centre, projection fit) and the screens' textures
pub struct Frame {
    pub mesh: Mesh,
    /// column-major view rotation
    pub rot: [f32; 9],
    pub centre: [f32; 3],
    /// x and y scale of the projected point to NDC, x and y offset in NDC
    pub fit: [f32; 4],
    /// camera distance, near, far (depth range)
    pub dnf: [f32; 3],
    pub inner: Option<egui::TextureId>,
    pub outer: Option<egui::TextureId>,
}

struct Gl {
    prog: glow::Program,
    quad: glow::Program,
    vao: glow::VertexArray,
    vbo: glow::Buffer,
    ibo: glow::Buffer,
    quad_vao: glow::VertexArray,
    quad_vbo: glow::Buffer,
    fbo: glow::Framebuffer,
    color: glow::Texture,
    depth: glow::Renderbuffer,
    size: (i32, i32),
    black: glow::Texture,
}

/// One drawing area's GL objects, made on first use
#[derive(Default, Clone)]
pub struct Target(Arc<Mutex<Option<Result<Gl, ()>>>>);

const VS: &str = r#"
uniform mat3 u_rot; uniform vec3 u_c; uniform vec4 u_fit; uniform vec3 u_dnf;
IN vec3 a_p; IN vec3 a_n; IN vec2 a_uv; IN float a_m;
OUT vec3 v_n; OUT vec3 v_p; OUT vec2 v_uv; OUT float v_m;
void main() {
    vec3 p = u_rot * a_p - u_c;
    float w = u_dnf.x - p.z;
    gl_Position = vec4(p.x * u_dnf.x * u_fit.x + u_fit.z * w, p.y * u_dnf.x * u_fit.y + u_fit.w * w,
        ((w - u_dnf.y) / (u_dnf.z - u_dnf.y) * 2.0 - 1.0) * w, w);
    v_n = u_rot * a_n; v_p = p; v_uv = a_uv; v_m = a_m;
}
"#;

const FS: &str = r#"
uniform sampler2D u_inner; uniform sampler2D u_outer; uniform vec3 u_dnf;
IN vec3 v_n; IN vec3 v_p; IN vec2 v_uv; IN float v_m;

// A photo studio around the camera, in view space (it stays put while the phone turns, as a product shot's lights
// do): a dark floor, a large softbox overhead, a tall strip light at each side and a faint card behind the camera.
// Reflections of it are what make metal and glass read as metal and glass.
float box(float x, float a, float b, float soft) { return smoothstep(a - soft, a + soft, x) * (1.0 - smoothstep(b - soft, b + soft, x)); }
vec3 studio(vec3 d) {
    float up = d.y * 0.5 + 0.5;
    vec3 c = mix(vec3(0.008, 0.008, 0.009), vec3(0.07, 0.071, 0.075), smoothstep(0.2, 0.9, up));
    // overhead softbox, a little in front
    c += vec3(2.0) * smoothstep(0.6, 0.8, d.y) * box(d.x, -0.55, 0.55, 0.12) * box(d.z, -0.2, 0.9, 0.15);
    // left strip, tall
    c += vec3(1.05, 1.03, 1.0) * smoothstep(0.78, 0.9, -d.x) * box(d.y, -0.3, 0.65, 0.12);
    // right strip, softer and cooler
    c += vec3(0.38, 0.40, 0.45) * smoothstep(0.8, 0.92, d.x) * box(d.y, -0.2, 0.6, 0.15);
    // a card behind the camera
    c += vec3(0.05) * smoothstep(0.8, 0.97, d.z);
    return c;
}
vec3 lin(vec3 g) { return pow(g, vec3(2.2)); }
vec3 srgb(vec3 l) { return pow(clamp(l, 0.0, 1.0), vec3(1.0 / 2.2)); }
vec3 tone(vec3 c) { return c * (2.51 * c + 0.03) / (c * (2.43 * c + 0.59) + 0.14); }

void main() {
    vec3 n = normalize(v_n);
    vec3 v = normalize(vec3(0.0, 0.0, u_dnf.x) - v_p);
    if (dot(n, v) < 0.0) n = -n;
    vec3 r = reflect(-v, n);
    float cosv = max(dot(n, v), 0.0);
    float fres = pow(1.0 - cosv, 5.0);
    vec3 col;
    if (v_m > 2.5 && v_m < 4.5) {
        // a screen: its picture as emitted light under cover glass
        vec3 pic = lin(v_m < 3.5 ? TEX(u_inner, v_uv).rgb : TEX(u_outer, v_uv).rgb);
        vec3 refl = studio(r) * (0.04 + 0.96 * fres);
        FRAG = vec4(srgb(pic + refl * 0.3), 1.0);
        return;
    }
    if (v_m < 0.5 || (v_m > 4.5 && v_m < 5.5)) {
        // the frame and spine: polished natural titanium (a metal: it shows its surroundings tinted by its colour)
        vec3 f0 = v_m < 0.5 ? vec3(0.56, 0.54, 0.51) : vec3(0.30, 0.30, 0.29);
        vec3 f = f0 + (vec3(1.0) - f0) * fres;
        col = f * studio(r) + f0 * 0.05;
    } else if (v_m < 1.5) {
        // back glass, frosted and dark: a broad, dim reflection over a little colour
        vec3 base = vec3(0.028, 0.029, 0.032);
        vec3 rr = normalize(mix(r, n, 0.35));
        col = base * (0.3 + 0.7 * max(dot(n, normalize(vec3(-0.4, 0.7, 0.6))), 0.0)) + studio(rr) * (0.04 + 0.96 * fres) * 0.45;
    } else if (v_m < 2.5) {
        // the front's black glass around the screen
        col = vec3(0.003) + studio(r) * (0.04 + 0.96 * fres) * 0.45;
    } else {
        // the spine's dark grooves
        col = vec3(0.01) + studio(r) * 0.02;
    }
    FRAG = vec4(srgb(tone(col)), 1.0);
}
"#;

const QVS: &str = r#"
IN vec2 a_p; OUT vec2 v_uv;
void main() { v_uv = a_p * 0.5 + 0.5; gl_Position = vec4(a_p, 0.0, 1.0); }
"#;
const QFS: &str = r#"
uniform sampler2D u_img; IN vec2 v_uv;
void main() { FRAG = TEX(u_img, v_uv); }
"#;

unsafe fn program(gl: &glow::Context, vs: &str, fs: &str, attrs: &[&str]) -> Result<glow::Program, String> {
    unsafe {
        let ver = egui_glow::ShaderVersion::get(gl);
        let new = ver.is_new_shader_interface();
        let prec = if ver.is_embedded() { "precision highp float;\n" } else { "" };
        let head_v = format!("{}{prec}#define IN {}\n#define OUT {}\n", ver.version_declaration(), if new { "in" } else { "attribute" }, if new { "out" } else { "varying" });
        let head_f = format!(
            "{}{prec}#define IN {}\n#define TEX {}\n{}",
            ver.version_declaration(),
            if new { "in" } else { "varying" },
            if new { "texture" } else { "texture2D" },
            if new { "out vec4 f_color;\n#define FRAG f_color\n" } else { "#define FRAG gl_FragColor\n" }
        );
        let p = gl.create_program()?;
        let mut shaders = vec![];
        for (kind, src) in [(glow::VERTEX_SHADER, head_v + vs), (glow::FRAGMENT_SHADER, head_f + fs)] {
            let s = gl.create_shader(kind)?;
            gl.shader_source(s, &src);
            gl.compile_shader(s);
            if !gl.get_shader_compile_status(s) {
                return Err(gl.get_shader_info_log(s));
            }
            gl.attach_shader(p, s);
            shaders.push(s);
        }
        for (i, a) in attrs.iter().enumerate() {
            gl.bind_attrib_location(p, i as u32, a);
        }
        gl.link_program(p);
        if !gl.get_program_link_status(p) {
            return Err(gl.get_program_info_log(p));
        }
        for s in shaders {
            gl.detach_shader(p, s);
            gl.delete_shader(s);
        }
        Ok(p)
    }
}

unsafe fn make(gl: &glow::Context) -> Result<Gl, String> {
    unsafe {
        let prog = program(gl, VS, FS, &["a_p", "a_n", "a_uv", "a_m"])?;
        let quad = program(gl, QVS, QFS, &["a_p"])?;
        let vao = gl.create_vertex_array()?;
        let vbo = gl.create_buffer()?;
        let ibo = gl.create_buffer()?;
        gl.bind_vertex_array(Some(vao));
        gl.bind_buffer(glow::ARRAY_BUFFER, Some(vbo));
        let stride = std::mem::size_of::<Vtx>() as i32;
        for (i, (n, off)) in [(3, 0), (3, 12), (2, 24), (1, 32)].into_iter().enumerate() {
            gl.enable_vertex_attrib_array(i as u32);
            gl.vertex_attrib_pointer_f32(i as u32, n, glow::FLOAT, false, stride, off);
        }
        gl.bind_buffer(glow::ELEMENT_ARRAY_BUFFER, Some(ibo));
        gl.bind_vertex_array(None);
        let quad_vao = gl.create_vertex_array()?;
        let quad_vbo = gl.create_buffer()?;
        gl.bind_vertex_array(Some(quad_vao));
        gl.bind_buffer(glow::ARRAY_BUFFER, Some(quad_vbo));
        let q: [f32; 8] = [-1.0, -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, 1.0];
        gl.buffer_data_u8_slice(glow::ARRAY_BUFFER, std::slice::from_raw_parts(q.as_ptr() as *const u8, 32), glow::STATIC_DRAW);
        gl.enable_vertex_attrib_array(0);
        gl.vertex_attrib_pointer_f32(0, 2, glow::FLOAT, false, 8, 0);
        gl.bind_vertex_array(None);
        let fbo = gl.create_framebuffer()?;
        let color = gl.create_texture()?;
        let depth = gl.create_renderbuffer()?;
        let black = gl.create_texture()?;
        gl.bind_texture(glow::TEXTURE_2D, Some(black));
        gl.tex_image_2d(glow::TEXTURE_2D, 0, glow::RGBA as i32, 1, 1, 0, glow::RGBA, glow::UNSIGNED_BYTE, glow::PixelUnpackData::Slice(Some(&[0, 0, 0, 255])));
        gl.tex_parameter_i32(glow::TEXTURE_2D, glow::TEXTURE_MIN_FILTER, glow::NEAREST as i32);
        gl.tex_parameter_i32(glow::TEXTURE_2D, glow::TEXTURE_MAG_FILTER, glow::NEAREST as i32);
        Ok(Gl { prog, quad, vao, vbo, ibo, quad_vao, quad_vbo, fbo, color, depth, size: (0, 0), black })
    }
}

unsafe fn resize(gl: &glow::Context, g: &mut Gl, w: i32, h: i32) {
    unsafe {
        if g.size == (w, h) {
            return;
        }
        g.size = (w, h);
        gl.bind_texture(glow::TEXTURE_2D, Some(g.color));
        gl.tex_image_2d(glow::TEXTURE_2D, 0, glow::RGBA8 as i32, w, h, 0, glow::RGBA, glow::UNSIGNED_BYTE, glow::PixelUnpackData::Slice(None));
        gl.tex_parameter_i32(glow::TEXTURE_2D, glow::TEXTURE_MIN_FILTER, glow::LINEAR as i32);
        gl.tex_parameter_i32(glow::TEXTURE_2D, glow::TEXTURE_MAG_FILTER, glow::LINEAR as i32);
        gl.tex_parameter_i32(glow::TEXTURE_2D, glow::TEXTURE_WRAP_S, glow::CLAMP_TO_EDGE as i32);
        gl.tex_parameter_i32(glow::TEXTURE_2D, glow::TEXTURE_WRAP_T, glow::CLAMP_TO_EDGE as i32);
        gl.bind_renderbuffer(glow::RENDERBUFFER, Some(g.depth));
        gl.renderbuffer_storage(glow::RENDERBUFFER, glow::DEPTH_COMPONENT24, w, h);
        gl.bind_framebuffer(glow::FRAMEBUFFER, Some(g.fbo));
        gl.framebuffer_texture_2d(glow::FRAMEBUFFER, glow::COLOR_ATTACHMENT0, glow::TEXTURE_2D, Some(g.color), 0);
        gl.framebuffer_renderbuffer(glow::FRAMEBUFFER, glow::DEPTH_ATTACHMENT, glow::RENDERBUFFER, Some(g.depth));
    }
}

impl Target {
    /// The paint callback drawing `frame` into the callback's rect
    pub fn callback(&self, frame: Frame) -> egui_glow::CallbackFn {
        let target = self.clone();
        let frame = Arc::new(frame);
        egui_glow::CallbackFn::new(move |info, painter| {
            let gl = painter.gl();
            let mut st = target.0.lock().unwrap();
            if st.is_none() {
                *st = Some(unsafe { make(gl) }.map_err(|e| eprintln!("duo3d: OpenGL setup failed: {e}")));
            }
            let Some(Ok(g)) = st.as_mut() else { return };
            let vp = info.viewport_in_pixels();
            let (w, h) = ((vp.width_px * 2).clamp(1, 8192), (vp.height_px * 2).clamp(1, 8192));
            let f = &frame;
            let black = g.black;
            let tex = |id: Option<egui::TextureId>| id.and_then(|i| painter.texture(i)).unwrap_or(black);
            unsafe {
                let prev_fbo = gl.get_parameter_i32(glow::DRAW_FRAMEBUFFER_BINDING);
                resize(gl, g, w, h);
                gl.bind_framebuffer(glow::FRAMEBUFFER, Some(g.fbo));
                gl.viewport(0, 0, w, h);
                gl.disable(glow::SCISSOR_TEST);
                gl.disable(glow::BLEND);
                gl.disable(glow::CULL_FACE);
                gl.enable(glow::DEPTH_TEST);
                gl.depth_func(glow::LEQUAL);
                gl.depth_mask(true);
                gl.clear_color(0.0, 0.0, 0.0, 0.0);
                gl.clear_depth_f32(1.0);
                gl.clear(glow::COLOR_BUFFER_BIT | glow::DEPTH_BUFFER_BIT);
                gl.use_program(Some(g.prog));
                let u = |n: &str| gl.get_uniform_location(g.prog, n);
                gl.uniform_matrix_3_f32_slice(u("u_rot").as_ref(), false, &f.rot);
                gl.uniform_3_f32(u("u_c").as_ref(), f.centre[0], f.centre[1], f.centre[2]);
                gl.uniform_4_f32(u("u_fit").as_ref(), f.fit[0], f.fit[1], f.fit[2], f.fit[3]);
                gl.uniform_3_f32(u("u_dnf").as_ref(), f.dnf[0], f.dnf[1], f.dnf[2]);
                gl.uniform_1_i32(u("u_inner").as_ref(), 0);
                gl.uniform_1_i32(u("u_outer").as_ref(), 1);
                gl.active_texture(glow::TEXTURE0);
                gl.bind_texture(glow::TEXTURE_2D, Some(tex(f.inner)));
                gl.active_texture(glow::TEXTURE1);
                gl.bind_texture(glow::TEXTURE_2D, Some(tex(f.outer)));
                gl.bind_vertex_array(Some(g.vao));
                gl.bind_buffer(glow::ARRAY_BUFFER, Some(g.vbo));
                let vb = std::slice::from_raw_parts(f.mesh.v.as_ptr() as *const u8, f.mesh.v.len() * std::mem::size_of::<Vtx>());
                gl.buffer_data_u8_slice(glow::ARRAY_BUFFER, vb, glow::STREAM_DRAW);
                gl.bind_buffer(glow::ELEMENT_ARRAY_BUFFER, Some(g.ibo));
                let ib = std::slice::from_raw_parts(f.mesh.i.as_ptr() as *const u8, f.mesh.i.len() * 4);
                gl.buffer_data_u8_slice(glow::ELEMENT_ARRAY_BUFFER, ib, glow::STREAM_DRAW);
                gl.draw_elements(glow::TRIANGLES, f.mesh.body as i32, glow::UNSIGNED_INT, 0);
                // the screens lie on the glass: drawn nearer by a depth offset
                gl.enable(glow::POLYGON_OFFSET_FILL);
                gl.polygon_offset(-1.0, -4.0);
                gl.draw_elements(glow::TRIANGLES, (f.mesh.i.len() - f.mesh.body) as i32, glow::UNSIGNED_INT, (f.mesh.body * 4) as i32);
                gl.disable(glow::POLYGON_OFFSET_FILL);
                gl.bind_vertex_array(None);
                gl.active_texture(glow::TEXTURE1);
                gl.bind_texture(glow::TEXTURE_2D, None);
                gl.active_texture(glow::TEXTURE0);
                // the picture, shrunk into the area over egui's drawing
                let prev = (prev_fbo > 0).then(|| glow::NativeFramebuffer(std::num::NonZeroU32::new(prev_fbo as u32).unwrap()));
                gl.bind_framebuffer(glow::FRAMEBUFFER, prev);
                gl.viewport(vp.left_px, vp.from_bottom_px, vp.width_px, vp.height_px);
                let clip = info.clip_rect_in_pixels();
                gl.enable(glow::SCISSOR_TEST);
                gl.scissor(clip.left_px, clip.from_bottom_px, clip.width_px, clip.height_px);
                gl.disable(glow::DEPTH_TEST);
                gl.enable(glow::BLEND);
                gl.blend_func(glow::ONE, glow::ONE_MINUS_SRC_ALPHA);
                gl.use_program(Some(g.quad));
                gl.uniform_1_i32(gl.get_uniform_location(g.quad, "u_img").as_ref(), 0);
                gl.bind_texture(glow::TEXTURE_2D, Some(g.color));
                gl.bind_vertex_array(Some(g.quad_vao));
                gl.draw_arrays(glow::TRIANGLE_STRIP, 0, 4);
                gl.bind_vertex_array(None);
                let _ = g.quad_vbo;
            }
        })
    }
}
