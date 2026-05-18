use rustler::types::atom::{error, ok};
use rustler::{Binary, Encoder, Env, NifResult, NewBinary, Term};
use sev::firmware::guest::{AttestationReport, Firmware};
use std::mem;

#[rustler::nif(schedule = "DirtyIo")]
fn supported<'a>(env: Env<'a>) -> NifResult<Term<'a>> {
    Ok((ok(), Firmware::open().is_ok()).encode(env))
}

#[rustler::nif(schedule = "DirtyIo")]
fn report<'a>(env: Env<'a>, report_data: Binary, vmpl: u32) -> NifResult<Term<'a>> {
    let report_data: [u8; 64] = match report_data.as_slice().try_into() {
        Ok(bytes) => bytes,
        Err(_) => return Ok((error(), "report_data must be exactly 64 bytes").encode(env)),
    };

    let mut firmware = match Firmware::open() {
        Ok(firmware) => firmware,
        Err(err) => return Ok((error(), format!("open /dev/sev-guest: {err:?}")).encode(env)),
    };

    match firmware.get_report(None, Some(report_data), Some(vmpl)) {
        Ok(report) => {
            let report_bytes = report_as_bytes(&report);
            let report_term = binary_term(env, report_bytes);
            let cert_terms: Vec<Term> = Vec::new();
            Ok((ok(), report_term, cert_terms).encode(env))
        }
        Err(err) => Ok((error(), format!("SNP_GET_REPORT: {err:?}")).encode(env)),
    }
}

fn report_as_bytes(report: &AttestationReport) -> &[u8] {
    unsafe {
        std::slice::from_raw_parts(
            (report as *const AttestationReport) as *const u8,
            mem::size_of::<AttestationReport>(),
        )
    }
}

fn binary_term<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut bin = NewBinary::new(env, bytes.len());
    bin.as_mut_slice().copy_from_slice(bytes);
    bin.into()
}

rustler::init!("dev_snp_nif");
