//! x86Sim: run MTLSimDriver's `astc` decode kernel (what the simulator uses for every ASTC texture) on the host
//! GPU through metal2vulkan, over a region of an ASTC 4x4 KTX file, and write the result as raw RGBA8.
//! Compare with a CPU decoder (tools/debug/astccmp.py). Usage:
//!   astctest <MTLSimDriver default.metallib> <file.ktx> <bx0> <by0> <blocks_w> <blocks_h> <out.rgba>
use metal2vulkan::library::Library;
use metal2vulkan::metal::{PixelFormat, TextureType, TextureUsage};
use metal2vulkan::pipeline::{ComputePipelineDescriptor, FunctionDescriptor, StageSource};
use metal2vulkan_runtime::{
    Buffer, Device, DeviceOptions, DispatchType, IndexClass, Instance, MemoryClass, Region, StorageMode, TextureDescriptor,
};

/// The first device above the runtime's floor.
fn device() -> Device {
    let instance = Instance::new(&[]).unwrap();
    let p = instance.physical_devices().unwrap().into_iter().find(|p| p.check().is_ok()).expect("no device above the floor");
    let d = Device::new(&p, DeviceOptions::default()).unwrap();
    d.grant_indices(IndexClass::Texture, 1, 16).unwrap();
    d
}

fn buffer_with(dev: &Device, bytes: &[u8]) -> Buffer {
    let block = dev.take_block(MemoryClass::Shared, bytes.len() as u64).unwrap();
    let b = dev.new_buffer(block.id, 0, bytes.len() as u64, None).unwrap();
    // SAFETY: a Shared buffer of bytes.len() bytes.
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), b.contents().unwrap().as_ptr(), bytes.len()) };
    b
}

fn hash52(mut p: u32) -> u32 {
    p ^= p >> 15;
    p = p.wrapping_sub(p << 17);
    p = p.wrapping_add(p << 7);
    p = p.wrapping_add(p << 4);
    p ^= p >> 5;
    p = p.wrapping_add(p << 16);
    p ^= p >> 7;
    p ^= p >> 3;
    p ^= p << 6;
    p ^= p >> 17;
    p
}

/// ASTC spec select_partition.
fn select_partition(seed: u32, mut x: u32, mut y: u32, mut z: u32, count: u32, small: bool) -> u8 {
    if small {
        x <<= 1;
        y <<= 1;
        z <<= 1;
    }
    let seed = seed + (count - 1) * 1024;
    let rnum = hash52(seed);
    let mut s = [0u32; 12];
    for i in 0..8 {
        s[i] = (rnum >> (4 * i)) & 0xF;
    }
    s[8] = (rnum >> 18) & 0xF;
    s[9] = (rnum >> 22) & 0xF;
    s[10] = (rnum >> 26) & 0xF;
    s[11] = ((rnum >> 30) | (rnum << 2)) & 0xF;
    for v in s.iter_mut() {
        *v *= *v;
    }
    let (sh1, sh2) = if seed & 1 != 0 {
        (if seed & 2 != 0 { 4 } else { 5 }, if count == 3 { 6 } else { 5 })
    } else {
        (if count == 3 { 6 } else { 5 }, if seed & 2 != 0 { 4 } else { 5 })
    };
    let sh3 = if seed & 0x10 != 0 { sh1 } else { sh2 };
    for (i, v) in s.iter_mut().enumerate() {
        *v >>= if i < 8 { if i % 2 == 0 { sh1 } else { sh2 } } else { sh3 };
    }
    let a = (s[0] * x + s[1] * y + s[10] * z + (rnum >> 14)) & 0x3F;
    let b = (s[2] * x + s[3] * y + s[11] * z + (rnum >> 10)) & 0x3F;
    let mut c = (s[4] * x + s[5] * y + s[8] * z + (rnum >> 6)) & 0x3F;
    let mut d = (s[6] * x + s[7] * y + s[9] * z + (rnum >> 2)) & 0x3F;
    if count < 4 {
        d = 0;
    }
    if count < 3 {
        c = 0;
    }
    if a >= b && a >= c && a >= d {
        0
    } else if b >= c && b >= d {
        1
    } else if c >= d {
        2
    } else {
        3
    }
}

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let lib_bytes = std::fs::read(&a[0]).unwrap();
    let ktx = std::fs::read(&a[1]).unwrap();
    let (bx0, by0, bw, bh): (usize, usize, usize, usize) = (a[2].parse().unwrap(), a[3].parse().unwrap(), a[4].parse().unwrap(), a[5].parse().unwrap());
    let u = |o: usize| u32::from_le_bytes(ktx[o..o + 4].try_into().unwrap()) as usize;
    let (w, kv) = (u(12 + 24), u(12 + 48));
    let data_off = 64 + kv + 4;
    let bpr_src = w.div_ceil(4) * 16;
    let mut input = Vec::with_capacity(bw * bh * 16);
    for by in 0..bh {
        let o = data_off + (by0 + by) * bpr_src + bx0 * 16;
        input.extend_from_slice(&ktx[o..o + bw * 16]);
    }
    // partition tables: bw*bh bytes per (count, seed), index ((count-2)*1024 + seed)
    let mut tables = vec![0u8; 3 * 1024 * 16];
    for count in 2..=4u32 {
        for seed in 0..1024u32 {
            for t in 0..16u32 {
                let i = (((count - 2) * 1024 + seed) * 16 + t) as usize;
                tables[i] = select_partition(seed, t % 4, t / 4, 0, count, true);
            }
        }
    }
    let zero = vec![0u8; 16];
    let mut params = [0u32; 14];
    params[0] = (bw * 4) as u32;
    params[1] = (bh * 4) as u32;
    params[2] = (bw * 16) as u32;
    params[3] = (bw * 16) as u32;
    params[11] = std::env::var("DECODE_MODE").ok().and_then(|s| s.parse().ok()).unwrap_or(0);
    params[12] = 4;
    params[13] = 4;
    let pbytes: Vec<u8> = params.iter().flat_map(|v| v.to_le_bytes()).collect();

    let dev = device();
    let lib = Library::parse(&lib_bytes).unwrap();
    let f = FunctionDescriptor::new(lib.function("astc").unwrap());
    let desc = ComputePipelineDescriptor::new(StageSource::Function(f));
    let pso = dev.new_compute_pipeline_state(&desc, |s| Ok(vec![0; s.len()])).unwrap();
    let ioff: usize = std::env::var("INPUT_OFFSET").ok().and_then(|s| s.parse().ok()).unwrap_or(0);
    let mut padded = vec![0xA5u8; ioff];
    padded.extend_from_slice(&input);
    let bin = buffer_with(&dev, &padded);
    let btab = buffer_with(&dev, &tables);
    let bzero = buffer_with(&dev, &zero);
    let pf = if params[11] == 1 { PixelFormat::RGBA16Float } else { PixelFormat::RGBA8Unorm };
    let mut td = TextureDescriptor::new(TextureType::Type2D, pf, (bw * 4) as u32, (bh * 4) as u32);
    td.usage = TextureUsage::try_from(3u32).unwrap();
    td.storage_mode = StorageMode::Shared;
    let tex = dev.new_texture(&td, Some(1)).unwrap();
    let q = dev.new_command_queue(64).unwrap();
    let cb = q.command_buffer().unwrap();
    let mut ce = cb.compute_command_encoder(DispatchType::Serial).unwrap();
    ce.set_compute_pipeline_state(&pso).unwrap();
    ce.set_buffer(Some(&bin), ioff as u64, 0).unwrap();
    ce.set_buffer(Some(&btab), 0, 1).unwrap();
    ce.set_bytes(&pbytes, 2).unwrap();
    ce.set_buffer(Some(&bzero), 0, 3).unwrap();
    ce.set_texture(Some(&tex), 0).unwrap();
    ce.dispatch_threads([bw as u32, bh as u32, 1], [8, 8, 1]).unwrap();
    ce.end_encoding();
    cb.commit().unwrap();
    cb.wait_until_completed().unwrap();
    let bpp = if params[11] == 1 { 8 } else { 4 };
    let mut out = vec![0u8; bw * 4 * bh * 4 * bpp];
    tex.get_bytes(&mut out, (bw * 4 * bpp) as u64, 0, Region { origin: [0; 3], size: [(bw * 4) as u32, (bh * 4) as u32, 1] }, 0, 0).unwrap();
    std::fs::write(&a[6], out).unwrap();
    println!("status {:?}", cb.status());
}
