pub(crate) mod TimestampInternalExterns {
    pub use tick_counter;

    #[cfg(target_arch = "aarch64")]
    const TSC_OFFSET: u64 = 26;

    #[cfg(target_arch = "x86_64")]
    const TSC_OFFSET: u64 = 32;

    pub(crate) struct _default {}

    impl _default {
        pub fn INTERNAL_ReadTimestamp() -> (bool, u32) {
            unsafe {
                let tsc: u64 = tick_counter::start() >> TSC_OFFSET;
                return (false, tsc.try_into().unwrap());
            }
        }
    }

    impl _default {
        pub fn INTERNAL_ReadTimestamp64() -> (bool, u64) {
            unsafe {
                let tsc: u64 = tick_counter::start();
                return (false, tsc);
            }
        }
    }
}

pub(crate) mod OutputInternalExterns {
    use std::io::{self, Write};

    pub(crate) struct _default {}

    impl _default {
        pub fn INTERNAL_FlushStdout() -> () {
            let _ = io::stdout().flush();
        }
    }
}

pub(crate) mod MonotonicTimerInternalExterns {
    use std::time::{SystemTime, UNIX_EPOCH};
    use dafny_runtime::*;

    pub(crate) struct _default {}

    impl _default {
        pub fn INTERNAL_ReadMonotonicNanos() -> DafnyInt {
            // Read wall-clock monotonic time in nanoseconds for validation against TSC
            match SystemTime::now().duration_since(UNIX_EPOCH) {
                Ok(duration) => DafnyInt::from(duration.as_nanos() as u64),
                Err(_) => DafnyInt::from(0),
            }
        }
    }
}

pub(crate) mod HashingExterns {
    pub use blake3;
    pub use dafny_runtime::string_of;
    pub use dafny_runtime::DafnyChar;
    pub use dafny_runtime::Object;
    pub use dafny_runtime::Sequence;
    pub use lazy_static::lazy_static;
    use rand::rngs::SysRng;
    use rand::TryRng;
    use std::fs;
    use std::fs::OpenOptions;
    use std::io::{Read, Write};
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    use std::path::Path;

    const BLOCK_SIZE: u32 = 4096;
    const SALT_LEN: usize = 32;
    const SALT_PATH: &str = "/var/lib/timelocked-storage/gatekeeper.hash_salt";

    fn random_salt() -> Vec<u8> {
        let mut s: Vec<u8> = vec![0; SALT_LEN];
        let mut rng = SysRng;
        rng.try_fill_bytes(&mut s).unwrap();
        s
    }

    fn ensure_salt_dir(path: &Path) {
        if let Some(parent) = path.parent() {
            if !parent.exists() {
                fs::create_dir_all(parent).expect("failed to create salt directory");
            }
            fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).ok();
        }
    }

    fn read_salt(path: &Path) -> Option<Vec<u8>> {
        let mut file = OpenOptions::new().read(true).open(path).ok()?;
        let mut salt = vec![0u8; SALT_LEN];
        file.read_exact(&mut salt).ok()?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).ok();
        Some(salt)
    }

    fn write_salt(path: &Path, salt_bytes: &[u8]) -> bool {
        match OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(path)
        {
            Ok(mut f) => {
                if f.write_all(salt_bytes).is_err() {
                    return false;
                }
                let _ = f.sync_all();
                true
            }
            Err(_) => false,
        }
    }

    fn get_salt() -> Vec<u8> {
        let path = Path::new(SALT_PATH);
        ensure_salt_dir(path);

        if let Some(s) = read_salt(path) {
            return s;
        }

        let s = random_salt();
        if write_salt(path, &s) {
            return s;
        }

        if let Some(existing) = read_salt(path) {
            return existing;
        }

        panic!("failed to initialize persistent gatekeeper hash salt at {}", SALT_PATH);
    }

    lazy_static! {
        static ref HASH_SALT: Vec<u8> = get_salt();
        static ref HASH_KEY: [u8; SALT_LEN] = {
            let mut key = [0u8; SALT_LEN];
            key.copy_from_slice(&HASH_SALT[..SALT_LEN]);
            key
        };
        static ref KEYED_HASHER: blake3::Hasher = blake3::Hasher::new_keyed(&*HASH_KEY);
    }

    pub(crate) struct _default {}

    impl _default {
        pub fn INTERNAL_HashBlock(
            bytes: &Object<[u8]>,
            md: u32,
            counter: u32,
        ) -> (bool) {
            let mut mut_block = bytes.clone();
            let mut hash_block: &mut [u8] = mut_block.as_mut();
            hash_block[BLOCK_SIZE as usize..(BLOCK_SIZE + 4) as usize]
                .copy_from_slice(&md.to_le_bytes());
            hash_block[(BLOCK_SIZE + 4) as usize..(BLOCK_SIZE + 8) as usize]
                .copy_from_slice(&counter.to_le_bytes());
            let mut hasher = KEYED_HASHER.clone();
            hasher.update(&hash_block[..(BLOCK_SIZE + 8) as usize]);
            let hash = hasher.finalize();
            hash_block[(BLOCK_SIZE + 8) as usize..(BLOCK_SIZE + 8 + 32) as usize]
                .copy_from_slice(hash.as_bytes());
            return false;
        }

        pub fn INTERNAL_CheckHash(bytes: &Object<[u8]>, offset: u32) -> (bool, bool) {
            let bytes_arr: &[u8] = bytes.as_ref();

            let mut hasher = KEYED_HASHER.clone();
            hasher.update(&bytes_arr[offset as usize..(offset + BLOCK_SIZE + 8) as usize]);
            let hash = hasher.finalize();
            let slice: &[u8; 32] = bytes_arr
                [(offset + BLOCK_SIZE + 8) as usize..(offset + BLOCK_SIZE + 8 + 32) as usize]
                .try_into()
                .unwrap();
            let hash_eq: bool = hash.as_bytes() == slice;
            return (false, hash_eq);
        }
    }
}

pub(crate) mod SharedInternalExterns {
    pub use dafny_runtime::Object;
    use std::ptr;

    pub(crate) struct _default {}

    impl _default {
        pub fn INTERNAL_copy_array(
            a: &Object<[u8]>,
            a_offset: u32,
            b: &Object<[u8]>,
            b_offset: u32,
            size: u32,
        ) {
            unsafe {
                let src_ptr = b.as_ref().as_ptr().add(b_offset as usize);
                let dst_ptr = a.as_ref().as_ptr() as *mut u8;
                let dst_ptr = dst_ptr.add(a_offset as usize);
                ptr::copy_nonoverlapping(src_ptr, dst_ptr, size as usize);
            }
        }
    }
}

pub(crate) mod InterfaceInternalExterns {
    pub use dafny_runtime::seq;
    pub use dafny_runtime::string_of;
    pub use dafny_runtime::DafnyChar;
    pub use dafny_runtime::Sequence;
    pub use dafny_runtime::Object;
    pub use dafny_runtime::_System::nat;
    pub use dafny_runtime::array;
    pub use dafny_runtime::integer_range;
    use lazy_static::lazy_static;
    use dafny_runtime::update_field_mut_nodrop_object;
    pub use std::mem::MaybeUninit;
    use std::{
        fs::OpenOptions,
        io,
        io::Read,
        io::Write,
        mem,
        net::SocketAddr,
        net::TcpListener,
        net::TcpStream,
        os::unix::fs::OpenOptionsExt,
        os::unix::io::AsRawFd,
        ptr,
        sync::Mutex,
        sync::atomic::{AtomicU32, AtomicUsize, Ordering},
    };
    use std::rc::Rc;

    extern crate libc;

    const LISTENER_PORT: u16 = 10107;
    const IPC_SHM_PATH: &str = "/dev/shm/timelocked_ipc";
    const IPC_RING_CAP: usize = 4 * 1024 * 1024;

    #[repr(C, align(64))]
    struct ShmPipe {
        head: AtomicU32,
        tail: AtomicU32,
        _pad: [u32; 14],
        buf: [u8; IPC_RING_CAP],
    }

    #[repr(C)]
    struct ShmChannel {
        c2s: ShmPipe,
        s2c: ShmPipe,
    }

    #[derive(Clone, Copy, PartialEq, Eq)]
    enum TransportMode {
        Tcp,
        Ipc,
    }

    const STREAM_READ_BUFFER_CAP: usize = 256 * 1024;

    struct ConnectionState {
        stream: TcpStream,
        recv_buf: Vec<u8>,
        recv_off: usize,
        recv_len: usize,
    }

    impl ConnectionState {
        fn new(stream: TcpStream) -> Self {
            Self {
                stream,
                recv_buf: vec![0u8; STREAM_READ_BUFFER_CAP],
                recv_off: 0,
                recv_len: 0,
            }
        }

        fn recv_exact(&mut self, out: &mut [u8]) -> io::Result<()> {
            let mut out_off = 0usize;

            while out_off < out.len() {
                if self.recv_off == self.recv_len {
                    let n = self.stream.read(&mut self.recv_buf)?;
                    if n == 0 {
                        return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "connection closed"));
                    }
                    self.recv_off = 0;
                    self.recv_len = n;
                }

                let avail = self.recv_len - self.recv_off;
                let need = out.len() - out_off;
                let to_copy = avail.min(need);

                out[out_off..out_off + to_copy]
                    .copy_from_slice(&self.recv_buf[self.recv_off..self.recv_off + to_copy]);

                self.recv_off += to_copy;
                out_off += to_copy;
            }

            Ok(())
        }
    }

    fn ipc_wait(addr: &AtomicU32, expected: u32) {
        unsafe {
            let _ = libc::syscall(
                libc::SYS_futex,
                addr as *const AtomicU32 as *const u32,
                libc::FUTEX_WAIT,
                expected as libc::c_int,
                ptr::null::<libc::timespec>(),
                ptr::null::<u32>(),
                0,
            );
        }
    }

    fn ipc_wake(addr: &AtomicU32) {
        unsafe {
            let _ = libc::syscall(
                libc::SYS_futex,
                addr as *const AtomicU32 as *const u32,
                libc::FUTEX_WAKE,
                1 as libc::c_int,
                ptr::null::<libc::timespec>(),
                ptr::null::<u32>(),
                0,
            );
        }
    }

    fn pipe_read(pipe: &ShmPipe, out: &mut [u8]) {
        let mut remaining = out.len();
        let mut out_off = 0usize;
        while remaining > 0 {
            let mut head = pipe.head.load(Ordering::Relaxed);
            let mut tail = pipe.tail.load(Ordering::Acquire);
            while tail == head {
                ipc_wait(&pipe.tail, tail);
                tail = pipe.tail.load(Ordering::Acquire);
            }

            let avail = (tail.wrapping_sub(head)) as usize;
            let was_full = avail == IPC_RING_CAP;
            let to_copy = avail.min(remaining);
            let head_idx = (head as usize) & (IPC_RING_CAP - 1);
            let first = (IPC_RING_CAP - head_idx).min(to_copy);
            out[out_off..out_off + first].copy_from_slice(&pipe.buf[head_idx..head_idx + first]);
            if first < to_copy {
                out[out_off + first..out_off + to_copy].copy_from_slice(&pipe.buf[..to_copy - first]);
            }

            out_off += to_copy;
            remaining -= to_copy;
            head = head.wrapping_add(to_copy as u32);
            pipe.head.store(head, Ordering::Release);
            if was_full {
                ipc_wake(&pipe.head);
            }
        }
    }

    fn pipe_write(pipe: &ShmPipe, input: &[u8]) {
        let mut remaining = input.len();
        let mut in_off = 0usize;
        while remaining > 0 {
            let mut tail = pipe.tail.load(Ordering::Relaxed);
            let mut head = pipe.head.load(Ordering::Acquire);
            let was_empty = tail == head;
            while tail.wrapping_sub(head) as usize >= IPC_RING_CAP {
                ipc_wait(&pipe.head, head);
                head = pipe.head.load(Ordering::Acquire);
            }

            let space = IPC_RING_CAP - (tail.wrapping_sub(head) as usize);
            let to_copy = space.min(remaining);
            let tail_idx = (tail as usize) & (IPC_RING_CAP - 1);
            let first = (IPC_RING_CAP - tail_idx).min(to_copy);

            unsafe {
                ptr::copy_nonoverlapping(
                    input.as_ptr().add(in_off),
                    pipe.buf.as_ptr().add(tail_idx) as *mut u8,
                    first,
                );
                if first < to_copy {
                    ptr::copy_nonoverlapping(
                        input.as_ptr().add(in_off + first),
                        pipe.buf.as_ptr() as *mut u8,
                        to_copy - first,
                    );
                }
            }

            in_off += to_copy;
            remaining -= to_copy;
            tail = tail.wrapping_add(to_copy as u32);
            pipe.tail.store(tail, Ordering::Release);
            if was_empty {
                ipc_wake(&pipe.tail);
            }
        }
    }

    fn create_ipc_channel() -> std::io::Result<*mut ShmChannel> {
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(IPC_SHM_PATH)?;
        file.set_len(mem::size_of::<ShmChannel>() as u64)?;

        let map = unsafe {
            libc::mmap(
                ptr::null_mut(),
                mem::size_of::<ShmChannel>(),
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                file.as_raw_fd(),
                0,
            )
        };
        if map == libc::MAP_FAILED {
            return Err(std::io::Error::last_os_error());
        }

        unsafe {
            ptr::write_bytes(map, 0, mem::size_of::<ShmChannel>());
        }
        Ok(map as *mut ShmChannel)
    }

    fn ipc_channel_ptr() -> Option<*mut ShmChannel> {
        let addr = ipc_channel_addr.load(Ordering::Acquire);
        if addr == 0 {
            None
        } else {
            Some(addr as *mut ShmChannel)
        }
    }

    lazy_static! {
        static ref listener: TcpListener =
            TcpListener::bind(SocketAddr::from(([0, 0, 0, 0], LISTENER_PORT))).unwrap();
        static ref stream_slot: Mutex<Option<ConnectionState>> = Mutex::new(None);
        static ref transport_mode: Mutex<TransportMode> = Mutex::new(TransportMode::Tcp);
        // Store mmap base address as usize to keep Lazy<...>: Sync-compatible.
        static ref ipc_channel_addr: AtomicUsize = AtomicUsize::new(0);
    }

    fn receive_n_bytes(dst: &mut [u8]) -> Result<TransportMode, Sequence<DafnyChar>> {
        let mode = *transport_mode.lock().unwrap();
        match mode {
            TransportMode::Ipc => {
                if let Some(ch_ptr) = ipc_channel_ptr() {
                    let channel = unsafe { &*ch_ptr };
                    pipe_read(&channel.c2s, dst);
                    Ok(TransportMode::Ipc)
                } else {
                    Err(string_of("IPC receive before init"))
                }
            }
            TransportMode::Tcp => {
                let mut stream_state = stream_slot.lock().unwrap();
                if let Some(stream) = stream_state.as_mut() {
                    match stream.recv_exact(dst) {
                        Ok(_) => Ok(TransportMode::Tcp),
                        Err(e) => {
                            *stream_state = None;
                            Err(string_of(&format!("Receive error: {:?}", e)))
                        }
                    }
                } else {
                    Err(string_of("Failed to receive"))
                }
            }
        }
    }

    pub fn set_transport_mode_ipc(enable: bool) {
        let mut mode = transport_mode.lock().unwrap();
        *mode = if enable { TransportMode::Ipc } else { TransportMode::Tcp };
    }

    pub(crate) struct _default {}

    impl _default {
        fn byte_to_disk_command(cmd: u8) -> Rc<crate::Shared::DiskCommand> {
            match cmd {
                0 => Rc::new(crate::Shared::DiskCommand::Read {}),
                1 => Rc::new(crate::Shared::DiskCommand::Write {}),
                2 => Rc::new(crate::Shared::DiskCommand::Sync {}),
                3 => Rc::new(crate::Shared::DiskCommand::InitCounters {}),
                4 => Rc::new(crate::Shared::DiskCommand::Finish {}),
                8 => Rc::new(crate::Shared::DiskCommand::Identify {}),
                _ => Rc::new(crate::Shared::DiskCommand::InvalidCommand {}),
            }
        }

        fn invalid_header() -> Rc<crate::Shared::DiskCmdHeader> {
            Rc::new(crate::Shared::DiskCmdHeader::DiskCmdHeader {
                num_data_ranges: 0,
                num_md_blocks: 0,
                disk_cmd: Rc::new(crate::Shared::DiskCommand::InvalidCommand {}),
                payload_size: 0,
            })
        }

        pub fn INTERNAL_interface_set_ipc_mode(enable: bool) {
            set_transport_mode_ipc(enable);
        }

        pub fn INTERNAL_interface_init(_port: u32) -> (bool, Sequence<DafnyChar>) {
            if *transport_mode.lock().unwrap() == TransportMode::Ipc {
                match create_ipc_channel() {
                    Ok(ch) => {
                        ipc_channel_addr.store(ch as usize, Ordering::Release);
                        return (false, string_of(""));
                    }
                    Err(e) => {
                        return (true, string_of(&format!("IPC init error: {:?}", e)));
                    }
                }
            }
            // println!{"init"};
            unsafe {
                let optval: libc::c_int = 1;
                let ret = libc::setsockopt(
                    listener.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_REUSEPORT,
                    &optval as *const _ as *const libc::c_void,
                    mem::size_of_val(&optval) as libc::socklen_t,
                );
                if ret != 0 {
                    return (true, string_of("Error in setting socket options"));
                }
            }
            return (false, string_of(""));
        }

        pub fn INTERNAL_interface_await_connection() -> (bool, Sequence<DafnyChar>) {
            if *transport_mode.lock().unwrap() == TransportMode::Ipc {
                return (false, string_of(""));
            }
            // println!{"accept"};
            let mut stream_state = stream_slot.lock().unwrap();
            match listener.accept() {
                Ok((socket, _addr)) => {
                    *stream_state = Some(ConnectionState::new(socket));
                }
                Err(e) => {
                    return (true, string_of("couldn't get client: {e:?}"));
                }
            }
            return (false, string_of(""));
        }

        
        pub fn INTERNAL_interface_send(
            payload: &Object<[u8]>,
            size: u32,
        ) -> (bool, Sequence<DafnyChar>) {
            let payload_arr: &[u8] = payload.as_ref();

            if *transport_mode.lock().unwrap() == TransportMode::Ipc {
                if let Some(ch_ptr) = ipc_channel_ptr() {
                    let channel = unsafe { &*ch_ptr };
                    pipe_write(&channel.s2c, &payload_arr[..size as usize]);
                    return (false, string_of(""));
                }
                return (true, string_of("IPC send before init"));
            }

            let mut stream_state = stream_slot.lock().unwrap();
            if let Some(stream) = stream_state.as_mut() {
                match stream.stream.write_all(&payload_arr[..size as usize]) {
                    Ok(_) => { /* success */ }
                    Err(e) => {
                        // Clear the connection state if the stream becomes invalid.
                        *stream_state = None;
                        return (true, string_of(&format!("Send error: {:?}", e)));
                    }
                }
            } else {
                return (true, string_of("inexplicable error"));
            }
            // println!{"sent {}", size};
            return (false, string_of(""));
        }

        pub fn INTERNAL_interface_receive(block: &Object<[u8]>, size: u32) -> (bool, Sequence<DafnyChar>) {
            // println!{"Recv block"};
            let mut mut_block = block.clone();
            let mut block_arr: &mut [u8] = mut_block.as_mut();

            match receive_n_bytes(&mut block_arr[..size as usize]) {
                Ok(_) => (false, string_of("")),
                Err(msg) => (true, msg),
            }
        }

        pub fn Bytes_to_DataRanges(
            num_ranges: u32,
            bytes: &Object<[u8]>,
            ranges: &Object<[Object<crate::Shared::DataRange>]>,
        ) -> (bool, Sequence<DafnyChar>) {
            const DATA_RANGE_SIZE: usize = 8;
            const NUM_BLOCKS_OFFSET: usize = 4;

            let src: &[u8] = bytes.as_ref();
            let mut ranges_mut = ranges.clone();
            let ranges_arr: &mut [Object<crate::Shared::DataRange>] = ranges_mut.as_mut();
            let num_ranges_usize = num_ranges as usize;

            if num_ranges_usize > ranges_arr.len() {
                return (true, string_of("num_ranges exceeds ranges array length"));
            }

            let needed = num_ranges_usize * DATA_RANGE_SIZE;
            if needed > src.len() {
                return (true, string_of("range bytes exceed request buffer"));
            }

            for (range_obj_ref, chunk) in ranges_arr[..num_ranges_usize]
                .iter()
                .zip(src[..needed].chunks_exact(DATA_RANGE_SIZE))
            {
                let pba = u32::from_le_bytes([
                    chunk[0],
                    chunk[1],
                    chunk[2],
                    chunk[3],
                ]);
                let num_blocks_u8 = chunk[NUM_BLOCKS_OFFSET];
                let num_blocks = num_blocks_u8 as u32;

                let range_obj = range_obj_ref.clone();
                update_field_mut_nodrop_object!(range_obj, pba, pba);
                update_field_mut_nodrop_object!(range_obj, num_blocks, num_blocks);
            }

            (false, string_of(""))
        }

        pub fn INTERNAL_receive_incoming_request(
            block: &Object<[u8]>,
            data_ranges: &Object<[Object<crate::Shared::DataRange>]>,
        ) -> (bool, Sequence<DafnyChar>, Rc<crate::Shared::DiskCmdHeader>, u32) {
            const HEADER_SIZE: usize = 12;
            const DATA_RANGE_SIZE: u32 = 8;
            const CMD_READ: u8 = 0;
            const CMD_WRITE: u8 = 1;

            let mut mut_block = block.clone();
            let block_arr: &mut [u8] = mut_block.as_mut();

            if block_arr.len() < HEADER_SIZE {
                return (true, string_of("request buffer too small"), Self::invalid_header(), 0);
            }

            let recv_into = |dst: &mut [u8]| -> Result<(), Sequence<DafnyChar>> {
                match receive_n_bytes(dst) {
                    Ok(TransportMode::Ipc) => Ok(()),
                    Ok(TransportMode::Tcp) => Ok(()),
                    Err(msg) => Err(msg),
                }
            };

            if let Err(msg) = recv_into(&mut block_arr[..HEADER_SIZE]) {
                return (true, msg, Self::invalid_header(), 0);
            }

            let payload_size = u32::from_le_bytes([block_arr[0], block_arr[1], block_arr[2], block_arr[3]]);
            let num_data_ranges = block_arr[4];
            let num_md_blocks = block_arr[8];
            let disk_cmd_byte = block_arr[9];
            let header = Rc::new(crate::Shared::DiskCmdHeader::DiskCmdHeader {
                num_data_ranges,
                num_md_blocks,
                disk_cmd: Self::byte_to_disk_command(disk_cmd_byte),
                payload_size,
            });

            if payload_size as usize > block_arr.len() {
                return (true, string_of("payload exceeds request buffer"), header, 0);
            }

            // Stage 1: read exactly the declared payload bytes.
            let mut received_payload_size = payload_size;
            if received_payload_size > 0 {
                if let Err(msg) = recv_into(&mut block_arr[..received_payload_size as usize]) {
                    return (true, msg, header, 0);
                }
            }

            // Stage 2: decode payload bytes into in-memory structures used by gatekeeper.
            let mut write_payload_size = 0u32;
            if disk_cmd_byte == CMD_READ || disk_cmd_byte == CMD_WRITE {
                let ranges_size = (num_data_ranges as u32) * DATA_RANGE_SIZE;
                if ranges_size > received_payload_size {
                    if disk_cmd_byte == CMD_READ {
                        if let Err(msg) = recv_into(&mut block_arr[received_payload_size as usize..ranges_size as usize]) {
                            return (true, msg, header, 0);
                        }
                        received_payload_size = ranges_size;
                    } else {
                        return (true, string_of(&format!(
                            "invalid ranges size in payload: ranges_size={} payload_size={} cmd={} num_data_ranges={} num_md_blocks={}",
                            ranges_size,
                            received_payload_size,
                            disk_cmd_byte,
                            num_data_ranges,
                            num_md_blocks
                        )), header, 0);
                    }
                }

                let (range_err, range_msg) = Self::Bytes_to_DataRanges(
                    num_data_ranges as u32,
                    block,
                    data_ranges,
                );
                if range_err {
                    return (true, range_msg, header, 0);
                }

                write_payload_size = received_payload_size - ranges_size;
                if write_payload_size > 0 {
                    let src_start = ranges_size as usize;
                    let src_end = (ranges_size + write_payload_size) as usize;
                    block_arr.copy_within(src_start..src_end, 0);
                }
            }

            (false, string_of(""), header, write_payload_size)
        }
    }
}

pub(crate) mod DiskIOInternalExterns {
    extern crate libc;
    pub use dafny_runtime::{array, string_of, DafnyChar, Object, Sequence};
    pub use lazy_static::lazy_static;
    pub use std::mem::MaybeUninit;
    pub use pakr_rawata::Device;
    pub use std::{
        ffi::CString, fs::File, io::Read, io::Seek, io::SeekFrom, io::Write, mem,
        os::fd::FromRawFd, os::raw::c_int, path, sync::Mutex,
    };

    // ---------------------------------------------------------------------------
    // Disk path resolution
    //
    // Resolution order (first match wins):
    //   1. GK_DISK_PATH environment variable
    //   2. `disk_path` key in a config file.  The config file is located by:
    //        a. GK_CONFIG environment variable  (absolute path to the file)
    //        b. gatekeeper.toml in the same directory as the running binary
    //        c. /etc/timelockdrive/gatekeeper.toml
    //
    // Config file format (TOML-subset, key = "value" lines, # comments ignored):
    //   disk_path = "/dev/ram0"
    // ---------------------------------------------------------------------------

    /// Parse `key = "value"` lines from a TOML-subset config file.
    /// Returns the value for `target_key`, or None if not found.
    fn parse_config_key(contents: &str, target_key: &str) -> Option<String> {
        for line in contents.lines() {
            let line = line.trim();
            if line.starts_with('#') || line.is_empty() {
                continue;
            }
            let mut parts = line.splitn(2, '=');
            let key = parts.next()?.trim();
            let raw_val = parts.next()?.trim();
            if key != target_key {
                continue;
            }
            // Strip surrounding quotes if present
            let val = if (raw_val.starts_with('"') && raw_val.ends_with('"'))
                || (raw_val.starts_with('\'') && raw_val.ends_with('\''))
            {
                raw_val[1..raw_val.len() - 1].to_string()
            } else {
                raw_val.to_string()
            };
            return Some(val);
        }
        None
    }

    /// Try to read `disk_path` from a config file.
    fn disk_path_from_config() -> Option<String> {
        use std::fs;

        // Candidate paths in priority order
        let mut candidates: Vec<std::path::PathBuf> = Vec::new();

        // a. GK_CONFIG env var
        if let Ok(p) = std::env::var("GK_CONFIG") {
            candidates.push(std::path::PathBuf::from(p));
        }

        // b. gatekeeper.toml next to the binary
        if let Ok(exe) = std::env::current_exe() {
            if let Some(dir) = exe.parent() {
                candidates.push(dir.join("gatekeeper.toml"));
            }
        }

        // c. System-wide default
        candidates.push(std::path::PathBuf::from("/etc/timelockdrive/gatekeeper.toml"));

        for path in &candidates {
            if let Ok(contents) = fs::read_to_string(path) {
                if let Some(val) = parse_config_key(&contents, "disk_path") {
                    eprintln!(
                        "[gatekeeper] disk_path = {:?}  (from {})",
                        val,
                        path.display()
                    );
                    return Some(val);
                }
            }
        }
        None
    }

    fn resolve_disk_path() -> String {
        // 1. Environment variable takes top priority
        if let Ok(p) = std::env::var("GK_DISK_PATH") {
            eprintln!("[gatekeeper] disk_path = {:?}  (from GK_DISK_PATH env)", p);
            return p;
        }
        // 2. Config file
        if let Some(p) = disk_path_from_config() {
            eprintln!("[gatekeeper] disk_path = {:?}  (from disk path config)", p);
            return p;
        }
        panic!("No disk path was specified.");
    }

    const BLOCK_SIZE: u32 = 4096;

    fn is_ram_disk(path: &str) -> bool {
        path.starts_with("/dev/ram")
    }

    lazy_static! {
        static ref DISK_PATH_RESOLVED: String = resolve_disk_path();
        static ref USE_RAM_DISK: bool = is_ram_disk(DISK_PATH_RESOLVED.as_str());
        // For RAM disks: plain O_RDWR file descriptor (no O_DIRECT — brd doesn't require it
        // and avoids alignment constraints on caller-supplied buffers)
        static ref ram_disk_fd: Option<Mutex<c_int>> = {
            if *USE_RAM_DISK {
                let fd = unsafe {
                    libc::open(
                        CString::new(DISK_PATH_RESOLVED.as_str()).unwrap().as_ptr(),
                        libc::O_RDWR,
                        0o644 as c_int,
                    )
                };
                assert!(fd >= 0, "Failed to open RAM disk: {}", DISK_PATH_RESOLVED.as_str());
                Some(Mutex::new(fd))
            } else {
                None
            }
        };
        // For physical disks: ATA passthrough via pakr-rawata
        static ref disk_mux: Option<Mutex<Device>> = {
            if !*USE_RAM_DISK {
                Some(Mutex::new(Device::open(path::Path::new(DISK_PATH_RESOLVED.as_str())).unwrap()))
            } else {
                None
            }
        };
        static ref disk_sync: Mutex<File> = Mutex::new(unsafe {
            File::from_raw_fd(libc::open(
                CString::new(DISK_PATH_RESOLVED.as_str()).unwrap().as_ptr(),
                (libc::O_DIRECT | libc::O_RDWR),
                0o644 as c_int,
            ))
        });
    }

    pub(crate) struct _default {}

    impl _default {
        pub fn INTERNAL_ReadBytesFromDisk(block_id: u32, num_blocks: u32, bytes: &Object<[u8]>) -> (bool, Sequence<DafnyChar>) {
            if num_blocks == 0 {
                return (true, string_of("num_blocks cannot be 0"));
            }

            let mut bytes_mut = bytes.clone();
            let bytes_buffer: &mut [u8] = bytes_mut.as_mut();
            let read_len = (BLOCK_SIZE * num_blocks) as usize;

            // Bounds check
            if bytes_buffer.len() < read_len {
                return (true, string_of(&format!(
                    "Buffer too small: need {}, have {}",
                    read_len, bytes_buffer.len()
                )));
            }

            if *USE_RAM_DISK {
                let fd = *ram_disk_fd.as_ref().unwrap().lock().unwrap();
                let byte_offset = block_id as i64 * BLOCK_SIZE as i64;
                let ret = unsafe {
                    libc::pread64(
                        fd,
                        bytes_buffer.as_mut_ptr() as *mut libc::c_void,
                        read_len,
                        byte_offset,
                    )
                };
                if ret < 0 || ret as usize != read_len {
                    (true, string_of(&format!("pread64 failed: ret={} errno={}", ret, unsafe { *libc::__errno_location() })))
                } else {
                    (false, string_of(""))
                }
            } else {
                let mut disk = disk_mux.as_ref().unwrap().lock().unwrap();
                match disk.read(((block_id as u64 * 8) as u64).into(), &mut bytes_buffer[..read_len]) {
                    Ok(_) => (false, string_of("")),
                    Err(e) => (true, string_of(&format!("Read error: {:?}", e)))
                }
            }
        }

        pub fn INTERNAL_WriteBytesToDisk(block_id: u32, num_blocks: u32, bytes: &Object<[u8]>, bytes_offset: u32) -> (bool, Sequence<DafnyChar>) {
            let bytes_arr: &[u8] = bytes.as_ref();
            let slice: &[u8] = &bytes_arr[bytes_offset as usize..(bytes_offset + (num_blocks * BLOCK_SIZE)) as usize];

            if *USE_RAM_DISK {
                let fd = *ram_disk_fd.as_ref().unwrap().lock().unwrap();
                let byte_offset = block_id as i64 * BLOCK_SIZE as i64;
                let ret = unsafe {
                    libc::pwrite64(
                        fd,
                        slice.as_ptr() as *const libc::c_void,
                        slice.len(),
                        byte_offset,
                    )
                };
                if ret < 0 || ret as usize != slice.len() {
                    (true, string_of(&format!("pwrite64 failed: ret={} errno={}", ret, unsafe { *libc::__errno_location() })))
                } else {
                    (false, string_of(""))
                }
            } else {
                let mut disk = disk_mux.as_ref().unwrap().lock().unwrap();
                match disk.write((block_id as u64 * 8) as u64, slice) {
                    Ok(_) => (false, string_of("")),
                    Err(e) => (true, string_of(&format!("Write error: {:?}", e)))
                }
            }
        }


        pub fn INTERNAL_Sync() -> (bool, Sequence<DafnyChar>) {
            // println!{"Sync"};
            let _ = disk_sync.lock().unwrap().flush();
            return (false, string_of(""));
        }

        pub fn INTERNAL_PrintCounters() {
            println!("Temporarily removed, should add this back later?\n");
        }
    }
}
