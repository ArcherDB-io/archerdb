use anyhow::Result as AnyResult;
use anyhow::{bail, Context};
use futures::executor::block_on;
use std::mem;
use std::str::FromStr;

use archerdb as tb;
use tb::arch_client as tbc;

const QUERY_UUID_STATUS_NOT_FOUND: u8 = 200;

struct CliArgs {
    cluster_id: u128,
    addresses: String,
}

fn main() -> AnyResult<()> {
    let args = std::env::args();
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();

    let args = CliArgs::parse(args)?;
    let mut input = Input::from(stdin);
    let mut output = Output::from(stdout);

    let mut client = tb::Client::new(args.cluster_id, &args.addresses)?;

    while let Some(op) = input.receive()? {
        let result = execute(&mut client, op)?;
        output.send(result)?;
    }

    Ok(())
}

fn execute(client: &mut tb::Client, op: Request) -> AnyResult<Reply> {
    match op {
        Request::InsertEvents(events) => {
            let response = client.insert_events(&events);
            let response = block_on(response)?;
            Ok(Reply::InsertEvents(response))
        }
        Request::QueryUuid(filter) => {
            let response = client.get_latest_by_uuid(filter.entity_id);
            let response = block_on(response)?;
            Ok(Reply::QueryUuid(build_query_uuid_reply(response)))
        }
        Request::QueryLatest(filter) => {
            let query = tb::LatestQuery {
                limit: filter.limit,
                group_id: filter.group_id,
                cursor_timestamp: filter.cursor_timestamp,
            };
            let response = client.query_latest(&query);
            let response = block_on(response)?;
            Ok(Reply::QueryLatest(response.events))
        }
    }
}

fn build_query_uuid_reply(event: Option<tb::GeoEvent>) -> QueryUuidReply {
    let mut bytes = Vec::new();
    let status = if event.is_some() { 0 } else { QUERY_UUID_STATUS_NOT_FOUND };
    let header = tbc::query_uuid_response_t {
        status,
        reserved: [0u8; 15],
    };
    bytes.extend_from_slice(as_bytes(&header));

    if let Some(event) = event {
        let raw: tbc::geo_event_t = event.into();
        bytes.extend_from_slice(as_bytes(&raw));
    }

    QueryUuidReply { bytes }
}

fn as_bytes<T>(value: &T) -> &[u8] {
    unsafe { std::slice::from_raw_parts((value as *const T) as *const u8, mem::size_of::<T>()) }
}

impl CliArgs {
    fn parse(mut args: std::env::Args) -> AnyResult<CliArgs> {
        let _arg0 = args.next();
        let arg1 = args.next();
        let arg2 = args.next();
        let (arg1, arg2) = match (arg1, arg2) {
            (Some(arg1), Some(arg2)) => (arg1, arg2),
            _ => bail!("two arguments required"),
        };

        let cluster_id: u128 =
            u128::from_str(&arg1).context("cluster id (argument 1) must be u128")?;
        let addresses = arg2;

        Ok(CliArgs {
            cluster_id,
            addresses,
        })
    }
}

enum Request {
    InsertEvents(Vec<tb::GeoEvent>),
    QueryUuid(tbc::query_uuid_filter_t),
    QueryLatest(tbc::query_latest_filter_t),
}

enum Reply {
    InsertEvents(Vec<tb::InsertError>),
    QueryUuid(QueryUuidReply),
    QueryLatest(Vec<tb::GeoEvent>),
}

struct QueryUuidReply {
    bytes: Vec<u8>,
}

struct Input {
    reader: Box<dyn std::io::Read>,
}

impl From<std::io::Stdin> for Input {
    fn from(stdin: std::io::Stdin) -> Input {
        Input {
            reader: Box::new(stdin),
        }
    }
}

impl Input {
    fn receive(&mut self) -> AnyResult<Option<Request>> {
        let op = {
            let mut bytes = [0; 1];
            if let Err(e) = self.reader.read_exact(&mut bytes) {
                if e.kind() == std::io::ErrorKind::UnexpectedEof {
                    return Ok(None);
                } else {
                    return Err(e.into());
                }
            }
            u8::from_le_bytes(bytes)
        };

        let event_count = {
            let mut bytes = [0; 4];
            self.reader.read_exact(&mut bytes)?;
            u32::from_le_bytes(bytes)
        };

        match op {
            tbc::ARCH_OPERATION_ARCH_OPERATION_INSERT_EVENTS => {
                let mut events = Vec::with_capacity(event_count as usize);
                for _ in 0..event_count {
                    let mut bytes = [0; mem::size_of::<tbc::geo_event_t>()];
                    self.reader.read_exact(&mut bytes)?;
                    let event: tbc::geo_event_t = unsafe { mem::transmute(bytes) };
                    events.push(tb::GeoEvent::from(event));
                }
                Ok(Some(Request::InsertEvents(events)))
            }
            tbc::ARCH_OPERATION_ARCH_OPERATION_QUERY_UUID => {
                if event_count != 1 {
                    bail!("query_uuid expects exactly one filter, got {event_count}");
                }
                let mut bytes = [0; mem::size_of::<tbc::query_uuid_filter_t>()];
                self.reader.read_exact(&mut bytes)?;
                let filter: tbc::query_uuid_filter_t = unsafe { mem::transmute(bytes) };
                Ok(Some(Request::QueryUuid(filter)))
            }
            tbc::ARCH_OPERATION_ARCH_OPERATION_QUERY_LATEST => {
                if event_count != 1 {
                    bail!("query_latest expects exactly one filter, got {event_count}");
                }
                let mut bytes = [0; mem::size_of::<tbc::query_latest_filter_t>()];
                self.reader.read_exact(&mut bytes)?;
                let filter: tbc::query_latest_filter_t = unsafe { mem::transmute(bytes) };
                Ok(Some(Request::QueryLatest(filter)))
            }
            _ => bail!("unsupported operation {op}"),
        }
    }
}

struct Output {
    writer: Box<dyn std::io::Write>,
}

impl From<std::io::Stdout> for Output {
    fn from(stdout: std::io::Stdout) -> Output {
        Output {
            writer: Box::new(stdout),
        }
    }
}

impl Output {
    fn send(&mut self, result: Reply) -> AnyResult<()> {
        match result {
            Reply::InsertEvents(results) => {
                let results_length = u32::try_from(results.len())?;
                self.writer.write_all(&results_length.to_le_bytes())?;
                for result in results {
                    let result = tbc::insert_geo_events_result_t {
                        index: result.index,
                        result: result.result as u32,
                    };
                    let bytes: [u8; mem::size_of::<tbc::insert_geo_events_result_t>()] =
                        unsafe { mem::transmute(result) };
                    self.writer.write_all(&bytes)?;
                }
            }
            Reply::QueryUuid(reply) => {
                let chunk_size = mem::size_of::<tbc::query_uuid_response_t>();
                if reply.bytes.len() % chunk_size != 0 {
                    bail!("query_uuid response has invalid size");
                }
                let count = reply.bytes.len() / chunk_size;
                let count = u32::try_from(count)?;
                self.writer.write_all(&count.to_le_bytes())?;
                self.writer.write_all(&reply.bytes)?;
            }
            Reply::QueryLatest(results) => {
                let results_length = u32::try_from(results.len())?;
                self.writer.write_all(&results_length.to_le_bytes())?;
                for result in results {
                    let raw: tbc::geo_event_t = result.into();
                    let bytes: [u8; mem::size_of::<tbc::geo_event_t>()] =
                        unsafe { mem::transmute(raw) };
                    self.writer.write_all(&bytes)?;
                }
            }
        }
        Ok(())
    }
}
