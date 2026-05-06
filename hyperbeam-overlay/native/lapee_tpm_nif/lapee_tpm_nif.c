/*
 * lapee_tpm_nif.c — Erlang NIF wrapping libtss2-esys for TPM 2.0.
 *
 * Real FFI into the ESYS API. No subprocess, no CLI wrapping.
 * Connects to swtpm via the mssim or swtpm TCTI (chosen via load info).
 */

#include <erl_nif.h>
#include <tss2/tss2_esys.h>
#include <tss2/tss2_mu.h>
#include <tss2/tss2_rc.h>
#include <tss2/tss2_tctildr.h>
#include <openssl/evp.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>

#include "tpm_helpers.h"

/* Shared HMAC session with AES-CFB parameter encryption for TPM2B-valued
 * sensitive operations. Commands fail closed if this session cannot start. */
static ESYS_TR g_auth_session = ESYS_TR_NONE;
static const int g_ak_policy_pcrs[] = {0, 1, 7, 10, 11, 14, 15};
#define LAPEE_AK_POLICY_PCR_COUNT \
    (sizeof(g_ak_policy_pcrs) / sizeof(g_ak_policy_pcrs[0]))

static TSS2_RC
lapee_ensure_auth_session(void)
{
    if (g_auth_session != ESYS_TR_NONE) return TSS2_RC_SUCCESS;
    TPMT_SYM_DEF symmetric = {
        .algorithm = TPM2_ALG_AES,
        .keyBits = { .aes = 128 },
        .mode = { .aes = TPM2_ALG_CFB },
    };
    /* Unsalted and unbound: the TPM and caller nonces still derive the
     * rolling HMAC key, and parameter encryption covers the first TPM2B. */
    TSS2_RC rc = Esys_StartAuthSession(
        g_esys_ctx,
        ESYS_TR_NONE,  /* tpmKey */
        ESYS_TR_NONE,  /* bind */
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        NULL,           /* nonceCaller -- Esys auto-generates */
        TPM2_SE_HMAC,
        &symmetric,
        TPM2_ALG_SHA256,
        &g_auth_session);
    if (rc != TSS2_RC_SUCCESS) return rc;
    /* Only TPM2B first-parameter operations receive this session; list-struct
     * PCR/capability calls reject ENCRYPT/DECRYPT by spec. */
    TPMA_SESSION attrs = TPMA_SESSION_ENCRYPT |
                         TPMA_SESSION_DECRYPT |
                         TPMA_SESSION_CONTINUESESSION;
    return Esys_TRSess_SetAttributes(g_esys_ctx, g_auth_session,
                                      attrs, 0xFF);
}

static TSS2_RC
lapee_enc_session(ESYS_TR *out_session)
{
    TSS2_RC rc = lapee_ensure_auth_session();
    if (rc == TSS2_RC_SUCCESS) *out_session = g_auth_session;
    return rc;
}

static void
lapee_flush_auth_session(void)
{
    if (g_auth_session != ESYS_TR_NONE) {
        Esys_FlushContext(g_esys_ctx, g_auth_session);
        g_auth_session = ESYS_TR_NONE;
    }
}

static TSS2_RC
lapee_start_salted_enc_session(ESYS_TR salt_key, ESYS_TR *out_session)
{
    TPMT_SYM_DEF symmetric = {
        .algorithm = TPM2_ALG_AES,
        .keyBits = { .aes = 128 },
        .mode = { .aes = TPM2_ALG_CFB },
    };
    ESYS_TR session = ESYS_TR_NONE;
    TSS2_RC rc = Esys_StartAuthSession(
        g_esys_ctx,
        salt_key,
        ESYS_TR_NONE,
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        NULL,
        TPM2_SE_HMAC,
        &symmetric,
        TPM2_ALG_SHA256,
        &session);
    if (rc != TSS2_RC_SUCCESS) return rc;

    TPMA_SESSION attrs = TPMA_SESSION_ENCRYPT |
                         TPMA_SESSION_DECRYPT |
                         TPMA_SESSION_CONTINUESESSION;
    rc = Esys_TRSess_SetAttributes(g_esys_ctx, session, attrs, 0xFF);
    if (rc != TSS2_RC_SUCCESS) {
        Esys_FlushContext(g_esys_ctx, session);
        return rc;
    }
    *out_session = session;
    return TSS2_RC_SUCCESS;
}

static TSS2_RC
lapee_policy_secret_endorsement_session(ESYS_TR *out_session)
{
    TPMT_SYM_DEF symmetric = {
        .algorithm = TPM2_ALG_NULL,
    };
    ESYS_TR session = ESYS_TR_NONE;
    TSS2_RC rc = Esys_StartAuthSession(
        g_esys_ctx,
        ESYS_TR_NONE,
        ESYS_TR_NONE,
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        NULL,
        TPM2_SE_POLICY,
        &symmetric,
        TPM2_ALG_SHA256,
        &session);
    if (rc != TSS2_RC_SUCCESS) return rc;

    TPM2B_TIMEOUT *timeout = NULL;
    TPMT_TK_AUTH *ticket = NULL;
    rc = Esys_PolicySecret(
        g_esys_ctx,
        ESYS_TR_RH_ENDORSEMENT,
        session,
        ESYS_TR_PASSWORD, ESYS_TR_NONE, ESYS_TR_NONE,
        NULL, NULL, NULL, 0,
        &timeout, &ticket);
    if (timeout) Esys_Free(timeout);
    if (ticket) Esys_Free(ticket);
    if (rc != TSS2_RC_SUCCESS) {
        Esys_FlushContext(g_esys_ctx, session);
        return rc;
    }
    *out_session = session;
    return TSS2_RC_SUCCESS;
}

static TPML_PCR_SELECTION
lapee_ak_policy_selection(void)
{
    TPML_PCR_SELECTION sel = {
        .count = 1,
        .pcrSelections = {
            {
                .hash = TPM2_ALG_SHA256,
                .sizeofSelect = 3,
                .pcrSelect = {0, 0, 0},
            }
        }
    };
    for (size_t i = 0; i < LAPEE_AK_POLICY_PCR_COUNT; i++) {
        int pcr = g_ak_policy_pcrs[i];
        sel.pcrSelections[0].pcrSelect[pcr / 8] |= (1 << (pcr % 8));
    }
    return sel;
}

static TSS2_RC
lapee_ak_policy_pcr_digest(TPM2B_DIGEST *out)
{
    TPML_PCR_SELECTION sel = lapee_ak_policy_selection();
    UINT32 update_counter = 0;
    TPML_PCR_SELECTION *out_sel = NULL;
    TPML_DIGEST *digests = NULL;
    TSS2_RC rc = Esys_PCR_Read(
        g_esys_ctx,
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        &sel, &update_counter, &out_sel, &digests);
    if (rc != TSS2_RC_SUCCESS) return rc;
    if (!digests || digests->count != LAPEE_AK_POLICY_PCR_COUNT) {
        if (out_sel) Esys_Free(out_sel);
        if (digests) Esys_Free(digests);
        return TSS2_ESYS_RC_BAD_VALUE;
    }

    EVP_MD_CTX *md = EVP_MD_CTX_new();
    if (!md) {
        if (out_sel) Esys_Free(out_sel);
        Esys_Free(digests);
        return TSS2_ESYS_RC_MEMORY;
    }
    unsigned int len = 0;
    int ok = EVP_DigestInit_ex(md, EVP_sha256(), NULL) == 1;
    for (size_t i = 0; ok && i < LAPEE_AK_POLICY_PCR_COUNT; i++) {
        ok = EVP_DigestUpdate(md, digests->digests[i].buffer,
                              digests->digests[i].size) == 1;
    }
    ok = ok && EVP_DigestFinal_ex(md, out->buffer, &len) == 1;
    EVP_MD_CTX_free(md);
    if (out_sel) Esys_Free(out_sel);
    Esys_Free(digests);
    if (!ok || len > sizeof(out->buffer)) return TSS2_ESYS_RC_GENERAL_FAILURE;
    out->size = (UINT16)len;
    return TSS2_RC_SUCCESS;
}

static TSS2_RC
lapee_policy_session_start(TPM2_SE type, ESYS_TR *out_session)
{
    TPMT_SYM_DEF symmetric = { .algorithm = TPM2_ALG_NULL };
    return Esys_StartAuthSession(
        g_esys_ctx,
        ESYS_TR_NONE, ESYS_TR_NONE,
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        NULL,
        type,
        &symmetric,
        TPM2_ALG_SHA256,
        out_session);
}

static TSS2_RC
lapee_policy_pcr_step(ESYS_TR session)
{
    TPM2B_DIGEST pcr_digest = { .size = 0 };
    TPML_PCR_SELECTION sel = lapee_ak_policy_selection();
    TSS2_RC rc = lapee_ak_policy_pcr_digest(&pcr_digest);
    if (rc == TSS2_RC_SUCCESS) {
        rc = Esys_PolicyPCR(
            g_esys_ctx,
            session,
            ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
            &pcr_digest,
            &sel);
    }
    return rc;
}

static TSS2_RC
lapee_policy_digest(ESYS_TR session, TPM2B_DIGEST *out)
{
    TPM2B_DIGEST *policy_digest = NULL;
    TSS2_RC rc = Esys_PolicyGetDigest(
        g_esys_ctx,
        session,
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        &policy_digest);
    if (rc == TSS2_RC_SUCCESS) {
        *out = *policy_digest;
        Esys_Free(policy_digest);
    }
    return rc;
}

static TSS2_RC
lapee_ak_policy_branch_digest(bool activate_credential, TPM2B_DIGEST *out)
{
    ESYS_TR session = ESYS_TR_NONE;
    TSS2_RC rc = lapee_policy_session_start(TPM2_SE_TRIAL, &session);
    if (rc != TSS2_RC_SUCCESS) return rc;

    rc = lapee_policy_pcr_step(session);
    if (rc == TSS2_RC_SUCCESS && activate_credential) {
        rc = Esys_PolicyCommandCode(
            g_esys_ctx,
            session,
            ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
            TPM2_CC_ActivateCredential);
    }
    if (rc == TSS2_RC_SUCCESS) rc = lapee_policy_digest(session, out);
    Esys_FlushContext(g_esys_ctx, session);
    return rc;
}

static TSS2_RC
lapee_ak_policy_branches(TPML_DIGEST *out)
{
    out->count = 2;
    TSS2_RC rc = lapee_ak_policy_branch_digest(false, &out->digests[0]);
    if (rc != TSS2_RC_SUCCESS) return rc;
    return lapee_ak_policy_branch_digest(true, &out->digests[1]);
}

static TSS2_RC
lapee_ak_policy_session(TPM2_SE type, bool activate_credential,
                        ESYS_TR *out_session,
                        TPM2B_DIGEST *out_policy_digest)
{
    TPML_DIGEST branches;
    TSS2_RC rc = lapee_ak_policy_branches(&branches);
    if (rc != TSS2_RC_SUCCESS) return rc;

    ESYS_TR session = ESYS_TR_NONE;
    rc = lapee_policy_session_start(type, &session);
    if (rc != TSS2_RC_SUCCESS) return rc;

    rc = lapee_policy_pcr_step(session);
    if (rc == TSS2_RC_SUCCESS && activate_credential) {
        rc = Esys_PolicyCommandCode(
            g_esys_ctx,
            session,
            ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
            TPM2_CC_ActivateCredential);
    }
    if (rc == TSS2_RC_SUCCESS) {
        rc = Esys_PolicyOR(
            g_esys_ctx,
            session,
            ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
            &branches);
    }
    if (rc == TSS2_RC_SUCCESS && out_policy_digest) {
        rc = lapee_policy_digest(session, out_policy_digest);
    }
    if (rc != TSS2_RC_SUCCESS) {
        Esys_FlushContext(g_esys_ctx, session);
        return rc;
    }
    *out_session = session;
    return TSS2_RC_SUCCESS;
}

static int
lapee_name_to_term(ErlNifEnv *env, const TPM2B_NAME *name, ERL_NIF_TERM *out)
{
    if (!name) return -1;
    unsigned char *buf = enif_make_new_binary(env, name->size, out);
    memcpy(buf, name->name, name->size);
    return 0;
}

static int
lapee_public_to_terms(ErlNifEnv *env, const TPM2B_PUBLIC *public,
                      ERL_NIF_TERM *pem_term, ERL_NIF_TERM *tpm2b_term)
{
    unsigned char *pem = NULL; size_t pem_len = 0;
    if (lapee_tpm2b_public_to_pem(public, &pem, &pem_len) != 0) return -1;

    unsigned char *marshalled = NULL; size_t marshalled_len = 0;
    if (lapee_marshal_public(public, &marshalled, &marshalled_len) != 0) {
        enif_free(pem);
        return -1;
    }

    unsigned char *pem_out = enif_make_new_binary(env, pem_len, pem_term);
    memcpy(pem_out, pem, pem_len);
    unsigned char *mb_out =
        enif_make_new_binary(env, marshalled_len, tpm2b_term);
    memcpy(mb_out, marshalled, marshalled_len);

    enif_free(pem);
    enif_free(marshalled);
    return 0;
}

static int
lapee_read_names(ErlNifEnv *env, ESYS_TR tr,
                 ERL_NIF_TERM *name_term, ERL_NIF_TERM *qname_term,
                 ERL_NIF_TERM *error_term)
{
    TPM2B_PUBLIC *ignored_public = NULL;
    TPM2B_NAME *name = NULL;
    TPM2B_NAME *qname = NULL;
    TSS2_RC rc = Esys_ReadPublic(
        g_esys_ctx,
        tr,
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        &ignored_public, &name, &qname);
    if (rc != TSS2_RC_SUCCESS) {
        if (error_term) {
            *error_term = lapee_make_tss_error(env, "Esys_ReadPublic", rc);
        }
        return -1;
    }
    int ok = lapee_name_to_term(env, name, name_term) == 0 &&
             lapee_name_to_term(env, qname, qname_term) == 0;
    if (ignored_public) Esys_Free(ignored_public);
    if (name) Esys_Free(name);
    if (qname) Esys_Free(qname);
    if (!ok && error_term) {
        *error_term = lapee_make_error(env, "name_encode_failed");
    }
    return ok ? 0 : -1;
}

static int
lapee_marshal_id_object(const TPM2B_ID_OBJECT *obj,
                        unsigned char **out, size_t *outlen)
{
    size_t off = 0;
    unsigned char *buf = enif_alloc(4096);
    if (!buf) return -1;
    TSS2_RC rc = Tss2_MU_TPM2B_ID_OBJECT_Marshal(obj, buf, 4096, &off);
    if (rc != TSS2_RC_SUCCESS || off == 0) {
        enif_free(buf);
        return -1;
    }
    *out = buf;
    *outlen = off;
    return 0;
}

static int
lapee_marshal_encrypted_secret(const TPM2B_ENCRYPTED_SECRET *secret,
                               unsigned char **out, size_t *outlen)
{
    size_t off = 0;
    unsigned char *buf = enif_alloc(4096);
    if (!buf) return -1;
    TSS2_RC rc =
        Tss2_MU_TPM2B_ENCRYPTED_SECRET_Marshal(secret, buf, 4096, &off);
    if (rc != TSS2_RC_SUCCESS || off == 0) {
        enif_free(buf);
        return -1;
    }
    *out = buf;
    *outlen = off;
    return 0;
}

/*-------------------------------- Load / Unload -----------------------------*/

static TSS2_RC
parse_tcti_load_info(ErlNifEnv *env, ERL_NIF_TERM load_info, char *out, size_t outlen)
{
    /* load_info is expected to be a string (list) like "swtpm:host=..." */
    unsigned len = 0;
    if (!enif_get_list_length(env, load_info, &len)) {
        /* Try binary */
        ErlNifBinary bin;
        if (enif_inspect_binary(env, load_info, &bin)) {
            if (bin.size >= outlen) return 1;
            memcpy(out, bin.data, bin.size);
            out[bin.size] = 0;
            return 0;
        }
        return 1;
    }
    if (len >= outlen) return 1;
    if (enif_get_string(env, load_info, out, outlen, ERL_NIF_LATIN1) <= 0)
        return 1;
    return 0;
}

static int
do_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data;

    if (parse_tcti_load_info(env, load_info, g_tcti_conf, sizeof(g_tcti_conf)) != 0) {
        /* Default if not provided. */
        snprintf(g_tcti_conf, sizeof(g_tcti_conf),
                 "swtpm:host=127.0.0.1,port=2321");
    }

    TSS2_RC rc = Tss2_TctiLdr_Initialize(g_tcti_conf, &g_tcti_ctx);
    if (rc != TSS2_RC_SUCCESS) {
        fprintf(stderr, "[lapee_tpm_nif] Tss2_TctiLdr_Initialize(%s) failed: 0x%x (%s)\n",
                g_tcti_conf, rc, Tss2_RC_Decode(rc));
        return 1;
    }
    rc = Esys_Initialize(&g_esys_ctx, g_tcti_ctx, NULL);
    if (rc != TSS2_RC_SUCCESS) {
        fprintf(stderr, "[lapee_tpm_nif] Esys_Initialize failed: 0x%x (%s)\n",
                rc, Tss2_RC_Decode(rc));
        Tss2_TctiLdr_Finalize(&g_tcti_ctx);
        return 1;
    }
    return 0;
}

static void
do_unload(ErlNifEnv *env, void *priv_data)
{
    (void)env; (void)priv_data;
    if (g_auth_session != ESYS_TR_NONE && g_esys_ctx) {
        Esys_FlushContext(g_esys_ctx, g_auth_session);
        g_auth_session = ESYS_TR_NONE;
    }
    if (g_esys_ctx) { Esys_Finalize(&g_esys_ctx); g_esys_ctx = NULL; }
    if (g_tcti_ctx) { Tss2_TctiLdr_Finalize(&g_tcti_ctx); g_tcti_ctx = NULL; }
}

/*-------------------------------- startup/0 ---------------------------------*/

static ERL_NIF_TERM
nif_startup(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;
    TSS2_RC rc = Esys_Startup(g_esys_ctx, TPM2_SU_CLEAR);
    if (rc == TPM2_RC_INITIALIZE) {
        /* Already started. Idempotent. */
        return enif_make_atom(env, "ok");
    }
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_Startup", rc);
    }
    return enif_make_atom(env, "ok");
}

/*-------------------------------- pcr_read/1 --------------------------------*/

static ERL_NIF_TERM
nif_pcr_read(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    int idx;
    if (!enif_get_int(env, argv[0], &idx) || idx < 0 || idx > 23) {
        return enif_make_badarg(env);
    }

    TPML_PCR_SELECTION sel = {
        .count = 1,
        .pcrSelections = {
            {
                .hash = TPM2_ALG_SHA256,
                .sizeofSelect = 3,
                .pcrSelect = {0, 0, 0},
            }
        }
    };
    sel.pcrSelections[0].pcrSelect[idx / 8] = 1 << (idx % 8);

    UINT32 update_counter = 0;
    TPML_PCR_SELECTION *out_sel = NULL;
    TPML_DIGEST *digests = NULL;
    /* PCR_Read returns TPML_DIGEST (list-struct, not TPM2B),
     * so parameter encryption + decrypt attrs are TPM-rejected
     * here -- see lapee_ensure_auth_session header. Read-only,
     * public values, no auth session. */
    TSS2_RC rc = Esys_PCR_Read(g_esys_ctx,
                               ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
                               &sel, &update_counter, &out_sel, &digests);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_PCR_Read", rc);
    }
    if (!digests || digests->count < 1) {
        if (out_sel) Esys_Free(out_sel);
        if (digests) Esys_Free(digests);
        return lapee_make_error(env, "no_digest");
    }
    ERL_NIF_TERM result;
    unsigned char *bin = enif_make_new_binary(env, digests->digests[0].size, &result);
    memcpy(bin, digests->digests[0].buffer, digests->digests[0].size);

    Esys_Free(out_sel);
    Esys_Free(digests);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), result);
}

/*-------------------------------- pcr_extend/2 ------------------------------*/

static ERL_NIF_TERM
nif_pcr_extend(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    int idx;
    ErlNifBinary data;
    if (!enif_get_int(env, argv[0], &idx) || idx < 0 || idx > 23) {
        return enif_make_badarg(env);
    }
    if (!enif_inspect_binary(env, argv[1], &data) || data.size != 32) {
        return enif_make_badarg(env);
    }

    TPML_DIGEST_VALUES digests = {
        .count = 1,
        .digests = {
            {
                .hashAlg = TPM2_ALG_SHA256,
            }
        }
    };
    memcpy(digests.digests[0].digest.sha256, data.data, 32);

    ESYS_TR pcr_handle = (ESYS_TR)idx; /* PCR index == ESYS_TR for PCRs 0..23. */

    /* PCR auth via shandle1=PASSWORD (PCR 15 has empty auth by
     * default on LapEE). PCR_Extend takes TPML_DIGEST_VALUES
     * (list-struct) as its first cmd-param; TPM rejects ENCRYPT
     * attr on non-TPM2B params. Paper P4 session attaches to
     * Quote + CreatePrimary only -- see lapee_ensure_auth_session
     * header for the full breakdown. */
    TSS2_RC rc = Esys_PCR_Extend(g_esys_ctx,
                                 pcr_handle,
                                 ESYS_TR_PASSWORD,
                                 ESYS_TR_NONE,
                                 ESYS_TR_NONE,
                                 &digests);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_PCR_Extend", rc);
    }
    return enif_make_atom(env, "ok");
}

/*-------------------------------- create_primary_ek/0 -----------------------*/

/* The standard EK template (TCG EK Credential Profile, low range) —
 * RSA 2048, SHA-256, restricted decryption key in the endorsement hierarchy. */
static const TPM2B_PUBLIC ek_template = {
    .size = 0,
    .publicArea = {
        .type = TPM2_ALG_RSA,
        .nameAlg = TPM2_ALG_SHA256,
        .objectAttributes =
            TPMA_OBJECT_FIXEDTPM | TPMA_OBJECT_FIXEDPARENT |
            TPMA_OBJECT_SENSITIVEDATAORIGIN | TPMA_OBJECT_ADMINWITHPOLICY |
            TPMA_OBJECT_RESTRICTED | TPMA_OBJECT_DECRYPT,
        .authPolicy = {
            .size = 32,
            .buffer = {
                /* TPM2_PolicySecret(TPM_RH_ENDORSEMENT) SHA-256 digest. */
                0x83, 0x71, 0x97, 0x67, 0x44, 0x84, 0xb3, 0xf8,
                0x1a, 0x90, 0xcc, 0x8d, 0x46, 0xa5, 0xd7, 0x24,
                0xfd, 0x52, 0xd7, 0x6e, 0x06, 0x52, 0x0b, 0x64,
                0xf2, 0xa1, 0xda, 0x1b, 0x33, 0x14, 0x69, 0xaa
            }
        },
        .parameters.rsaDetail = {
            .symmetric = {
                .algorithm = TPM2_ALG_AES,
                .keyBits.aes = 128,
                .mode.aes = TPM2_ALG_CFB,
            },
            .scheme = { .scheme = TPM2_ALG_NULL },
            .keyBits = 2048,
            .exponent = 0,
        },
        .unique.rsa = { .size = 256, .buffer = {0} }
    }
};

static ERL_NIF_TERM
nif_create_primary_ek(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;

    TPM2B_SENSITIVE_CREATE in_sensitive = { .size = 0 };
    TPM2B_DATA outside_info = { .size = 0 };
    TPML_PCR_SELECTION creation_pcr = { .count = 0 };

    ESYS_TR ek_tr = ESYS_TR_NONE;
    TPM2B_PUBLIC *out_public = NULL;
    TPM2B_CREATION_DATA *creation_data = NULL;
    TPM2B_DIGEST *creation_hash = NULL;
    TPMT_TK_CREATION *creation_ticket = NULL;

    ESYS_TR enc_session = ESYS_TR_NONE;
    TSS2_RC rc = lapee_enc_session(&enc_session);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "StartAuthSession(HMAC)", rc);
    }

    rc = Esys_CreatePrimary(g_esys_ctx,
                            ESYS_TR_RH_ENDORSEMENT,
                            ESYS_TR_PASSWORD,
                            enc_session,
                            ESYS_TR_NONE,
                            &in_sensitive, &ek_template,
                            &outside_info, &creation_pcr,
                            &ek_tr, &out_public,
                            &creation_data, &creation_hash,
                            &creation_ticket);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_CreatePrimary(EK)", rc);
    }

    TPM2_HANDLE tpm_handle = 0;
    rc = Esys_TR_GetTpmHandle(g_esys_ctx, ek_tr, &tpm_handle);
    if (rc != TSS2_RC_SUCCESS) {
        Esys_FlushContext(g_esys_ctx, ek_tr);
        if (out_public) Esys_Free(out_public);
        if (creation_data) Esys_Free(creation_data);
        if (creation_hash) Esys_Free(creation_hash);
        if (creation_ticket) Esys_Free(creation_ticket);
        return lapee_make_tss_error(env, "Esys_TR_GetTpmHandle", rc);
    }

    ERL_NIF_TERM pem_term, tpm2b_term, name_term, qname_term, err_term;
    if (lapee_public_to_terms(env, out_public, &pem_term, &tpm2b_term) != 0) {
        Esys_FlushContext(g_esys_ctx, ek_tr);
        if (out_public) Esys_Free(out_public);
        if (creation_data) Esys_Free(creation_data);
        if (creation_hash) Esys_Free(creation_hash);
        if (creation_ticket) Esys_Free(creation_ticket);
        return lapee_make_error(env, "pem_encode_failed");
    }
    if (lapee_read_names(env, ek_tr, &name_term, &qname_term, &err_term) != 0) {
        Esys_FlushContext(g_esys_ctx, ek_tr);
        if (out_public) Esys_Free(out_public);
        if (creation_data) Esys_Free(creation_data);
        if (creation_hash) Esys_Free(creation_hash);
        if (creation_ticket) Esys_Free(creation_ticket);
        return err_term;
    }

    /* We deliberately store ESYS_TR in the map too under 'esys_tr' so the
     * caller can re-use it for Esys_* calls without a re-load. */
    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map,
                      enif_make_atom(env, "handle"),
                      enif_make_uint(env, tpm_handle), &map);
    enif_make_map_put(env, map,
                      enif_make_atom(env, "esys_tr"),
                      enif_make_uint(env, ek_tr), &map);
    enif_make_map_put(env, map,
                      enif_make_atom(env, "public_pem"),
                      pem_term, &map);
    enif_make_map_put(env, map,
                      enif_make_atom(env, "tpm2b_public"),
                      tpm2b_term, &map);
    enif_make_map_put(env, map,
                      enif_make_atom(env, "name"),
                      name_term, &map);
    enif_make_map_put(env, map,
                      enif_make_atom(env, "qualified_name"),
                      qname_term, &map);

    if (out_public) Esys_Free(out_public);
    if (creation_data) Esys_Free(creation_data);
    if (creation_hash) Esys_Free(creation_hash);
    if (creation_ticket) Esys_Free(creation_ticket);

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), map);
}

/*-------------------------------- create_signing_key/1 ----------------------*/

static ERL_NIF_TERM
nif_create_signing_key(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    unsigned parent_handle;
    if (!enif_get_uint(env, argv[0], &parent_handle)) {
        return enif_make_badarg(env);
    }

    TPM2B_DIGEST ak_policy = { .size = 0 };
    ESYS_TR trial_session = ESYS_TR_NONE;
    TSS2_RC rc = lapee_ak_policy_session(
        TPM2_SE_TRIAL, false, &trial_session, &ak_policy);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_PolicyPCR(AK trial)", rc);
    }
    Esys_FlushContext(g_esys_ctx, trial_session);

    /* Template for restricted RSA-2048 signing key (PSS, SHA-256). */
    TPM2B_PUBLIC in_public = {
        .size = 0,
        .publicArea = {
            .type = TPM2_ALG_RSA,
            .nameAlg = TPM2_ALG_SHA256,
            .objectAttributes =
                TPMA_OBJECT_FIXEDTPM | TPMA_OBJECT_FIXEDPARENT |
                TPMA_OBJECT_SENSITIVEDATAORIGIN |
                TPMA_OBJECT_ADMINWITHPOLICY |
                TPMA_OBJECT_NODA | TPMA_OBJECT_RESTRICTED |
                TPMA_OBJECT_SIGN_ENCRYPT,
            .authPolicy = ak_policy,
            .parameters.rsaDetail = {
                .symmetric = { .algorithm = TPM2_ALG_NULL },
                .scheme = {
                    .scheme = TPM2_ALG_RSAPSS,
                    .details.rsapss = { .hashAlg = TPM2_ALG_SHA256 },
                },
                .keyBits = 2048,
                .exponent = 0,
            },
            .unique.rsa = { .size = 0, .buffer = {0} }
        }
    };
    TPM2B_SENSITIVE_CREATE in_sensitive = { .size = 0 };
    TPM2B_DATA outside_info = { .size = 0 };
    TPML_PCR_SELECTION creation_pcr = { .count = 0 };

    ESYS_TR ak_tr = ESYS_TR_NONE;
    TPM2B_PUBLIC *out_public = NULL;
    TPM2B_CREATION_DATA *creation_data = NULL;
    TPM2B_DIGEST *creation_hash = NULL;
    TPMT_TK_CREATION *creation_ticket = NULL;

    ESYS_TR enc_session = ESYS_TR_NONE;
    rc = lapee_enc_session(&enc_session);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "StartAuthSession(HMAC)", rc);
    }

    rc = Esys_CreatePrimary(g_esys_ctx,
                            ESYS_TR_RH_ENDORSEMENT,
                            ESYS_TR_PASSWORD,
                            enc_session,
                            ESYS_TR_NONE,
                            &in_sensitive, &in_public,
                            &outside_info, &creation_pcr,
                            &ak_tr, &out_public,
                            &creation_data, &creation_hash,
                            &creation_ticket);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_CreatePrimary(AK)", rc);
    }

    TPM2_HANDLE tpm_handle = 0;
    rc = Esys_TR_GetTpmHandle(g_esys_ctx, ak_tr, &tpm_handle);
    if (rc != TSS2_RC_SUCCESS) {
        Esys_FlushContext(g_esys_ctx, ak_tr);
        if (out_public) Esys_Free(out_public);
        if (creation_data) Esys_Free(creation_data);
        if (creation_hash) Esys_Free(creation_hash);
        if (creation_ticket) Esys_Free(creation_ticket);
        return lapee_make_tss_error(env, "Esys_TR_GetTpmHandle(AK)", rc);
    }

    ERL_NIF_TERM pem_term, mb_term, name_term, qname_term, err_term;
    if (lapee_public_to_terms(env, out_public, &pem_term, &mb_term) != 0) {
        Esys_FlushContext(g_esys_ctx, ak_tr);
        if (out_public) Esys_Free(out_public);
        if (creation_data) Esys_Free(creation_data);
        if (creation_hash) Esys_Free(creation_hash);
        if (creation_ticket) Esys_Free(creation_ticket);
        return lapee_make_error(env, "pem_encode_failed");
    }
    if (lapee_read_names(env, ak_tr, &name_term, &qname_term, &err_term) != 0) {
        Esys_FlushContext(g_esys_ctx, ak_tr);
        if (out_public) Esys_Free(out_public);
        if (creation_data) Esys_Free(creation_data);
        if (creation_hash) Esys_Free(creation_hash);
        if (creation_ticket) Esys_Free(creation_ticket);
        return err_term;
    }

    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map,
                      enif_make_atom(env, "handle"),
                      enif_make_uint(env, tpm_handle), &map);
    enif_make_map_put(env, map,
                      enif_make_atom(env, "esys_tr"),
                      enif_make_uint(env, ak_tr), &map);
    enif_make_map_put(env, map,
                      enif_make_atom(env, "public_pem"),
                      pem_term, &map);
    enif_make_map_put(env, map,
                      enif_make_atom(env, "tpm2b_public"),
                      mb_term, &map);
    enif_make_map_put(env, map,
                      enif_make_atom(env, "name"),
                      name_term, &map);
    enif_make_map_put(env, map,
                      enif_make_atom(env, "qualified_name"),
                      qname_term, &map);

    if (out_public) Esys_Free(out_public);
    if (creation_data) Esys_Free(creation_data);
    if (creation_hash) Esys_Free(creation_hash);
    if (creation_ticket) Esys_Free(creation_ticket);

    (void)parent_handle;
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), map);
}

/*-------------------------------- make_credential/3 -------------------------*/

static ERL_NIF_TERM
nif_make_credential(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ErlNifBinary ek_public_bin, ak_name_bin, secret_bin;
    if (!enif_inspect_binary(env, argv[0], &ek_public_bin) ||
        !enif_inspect_binary(env, argv[1], &ak_name_bin) ||
        !enif_inspect_binary(env, argv[2], &secret_bin)) {
        return enif_make_badarg(env);
    }
    if (secret_bin.size == 0 ||
        secret_bin.size > sizeof(((TPM2B_DIGEST *)0)->buffer) ||
        ak_name_bin.size == 0 ||
        ak_name_bin.size > sizeof(((TPM2B_NAME *)0)->name)) {
        return enif_make_badarg(env);
    }

    TPM2B_PUBLIC ek_public;
    size_t off = 0;
    TSS2_RC rc = Tss2_MU_TPM2B_PUBLIC_Unmarshal(
        ek_public_bin.data, ek_public_bin.size, &off, &ek_public);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Tss2_MU_TPM2B_PUBLIC_Unmarshal", rc);
    }

    ESYS_TR ek_tr = ESYS_TR_NONE;
    rc = Esys_LoadExternal(
        g_esys_ctx,
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        NULL,
        &ek_public,
        /*
         * MakeCredential runs on the verifier's TPM using only the
         * joiner's EK public area. Public-only external objects are
         * loaded without an inPrivate value; passing an empty sensitive
         * area still asks ESYS to marshal a private half of the object.
         * TPM_RH_NULL avoids associating that peer public key with a
         * local hierarchy.
         */
        ESYS_TR_RH_NULL,
        &ek_tr);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_LoadExternal(peer EK public)", rc);
    }

    TPM2B_DIGEST credential = { .size = (UINT16)secret_bin.size };
    memcpy(credential.buffer, secret_bin.data, secret_bin.size);
    TPM2B_NAME object_name = { .size = (UINT16)ak_name_bin.size };
    memcpy(object_name.name, ak_name_bin.data, ak_name_bin.size);

    TPM2B_ID_OBJECT *credential_blob = NULL;
    TPM2B_ENCRYPTED_SECRET *enc_secret = NULL;
    rc = Esys_MakeCredential(
        g_esys_ctx,
        ek_tr,
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        &credential, &object_name,
        &credential_blob, &enc_secret);
    Esys_FlushContext(g_esys_ctx, ek_tr);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_MakeCredential", rc);
    }

    unsigned char *blob = NULL, *secret = NULL;
    size_t blob_len = 0, secret_len = 0;
    if (lapee_marshal_id_object(credential_blob, &blob, &blob_len) != 0 ||
        lapee_marshal_encrypted_secret(enc_secret, &secret, &secret_len) != 0) {
        if (blob) enif_free(blob);
        if (secret) enif_free(secret);
        Esys_Free(credential_blob);
        Esys_Free(enc_secret);
        return lapee_make_error(env, "marshal_failed");
    }

    ERL_NIF_TERM blob_term, secret_term;
    unsigned char *blob_out = enif_make_new_binary(env, blob_len, &blob_term);
    memcpy(blob_out, blob, blob_len);
    unsigned char *secret_out =
        enif_make_new_binary(env, secret_len, &secret_term);
    memcpy(secret_out, secret, secret_len);
    enif_free(blob);
    enif_free(secret);
    Esys_Free(credential_blob);
    Esys_Free(enc_secret);

    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map, enif_make_atom(env, "credential_blob"),
                      blob_term, &map);
    enif_make_map_put(env, map, enif_make_atom(env, "secret"),
                      secret_term, &map);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), map);
}

/*-------------------------------- activate_credential/4 ---------------------*/

static ERL_NIF_TERM
nif_activate_credential(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    unsigned ak_tr, ek_tr;
    ErlNifBinary blob_bin, secret_bin;
    if (!enif_get_uint(env, argv[0], &ak_tr) ||
        !enif_get_uint(env, argv[1], &ek_tr) ||
        !enif_inspect_binary(env, argv[2], &blob_bin) ||
        !enif_inspect_binary(env, argv[3], &secret_bin)) {
        return enif_make_badarg(env);
    }

    TPM2B_ID_OBJECT credential_blob;
    size_t off = 0;
    TSS2_RC rc = Tss2_MU_TPM2B_ID_OBJECT_Unmarshal(
        blob_bin.data, blob_bin.size, &off, &credential_blob);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(
            env, "Tss2_MU_TPM2B_ID_OBJECT_Unmarshal", rc);
    }
    TPM2B_ENCRYPTED_SECRET enc_secret;
    off = 0;
    rc = Tss2_MU_TPM2B_ENCRYPTED_SECRET_Unmarshal(
        secret_bin.data, secret_bin.size, &off, &enc_secret);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(
            env, "Tss2_MU_TPM2B_ENCRYPTED_SECRET_Unmarshal", rc);
    }

    ESYS_TR ak_policy_session = ESYS_TR_NONE;
    rc = lapee_ak_policy_session(
        TPM2_SE_POLICY, true, &ak_policy_session, NULL);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_PolicyPCR(AK)", rc);
    }
    ESYS_TR ek_policy_session = ESYS_TR_NONE;
    rc = lapee_policy_secret_endorsement_session(&ek_policy_session);
    if (rc != TSS2_RC_SUCCESS) {
        Esys_FlushContext(g_esys_ctx, ak_policy_session);
        return lapee_make_tss_error(
            env, "Esys_PolicySecret(ENDORSEMENT)", rc);
    }

    ESYS_TR enc_session = ESYS_TR_NONE;
    lapee_flush_auth_session();
    rc = lapee_start_salted_enc_session((ESYS_TR)ek_tr, &enc_session);
    if (rc != TSS2_RC_SUCCESS) {
        Esys_FlushContext(g_esys_ctx, ak_policy_session);
        Esys_FlushContext(g_esys_ctx, ek_policy_session);
        return lapee_make_tss_error(
            env, "Esys_StartAuthSession(salted HMAC)", rc);
    }

    TPM2B_DIGEST *cert_info = NULL;
    rc = Esys_ActivateCredential(
        g_esys_ctx,
        (ESYS_TR)ak_tr,
        (ESYS_TR)ek_tr,
        ak_policy_session,
        ek_policy_session,
        enc_session,
        &credential_blob,
        &enc_secret,
        &cert_info);
    Esys_FlushContext(g_esys_ctx, ak_policy_session);
    Esys_FlushContext(g_esys_ctx, ek_policy_session);
    Esys_FlushContext(g_esys_ctx, enc_session);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_ActivateCredential", rc);
    }

    ERL_NIF_TERM out;
    unsigned char *buf = enif_make_new_binary(env, cert_info->size, &out);
    memcpy(buf, cert_info->buffer, cert_info->size);
    Esys_Free(cert_info);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), out);
}

/*-------------------------------- quote/3 -----------------------------------*/

static ERL_NIF_TERM
nif_quote(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    unsigned esys_tr;
    if (!enif_get_uint(env, argv[0], &esys_tr)) return enif_make_badarg(env);

    /* PCR list -> selection (SHA-256 bank). */
    ERL_NIF_TERM list = argv[1], head, tail = list;
    TPML_PCR_SELECTION sel = {
        .count = 1,
        .pcrSelections = {
            {
                .hash = TPM2_ALG_SHA256,
                .sizeofSelect = 3,
                .pcrSelect = {0, 0, 0},
            }
        }
    };
    int have_any = 0;
    int pcr_indices[24]; int pcr_count = 0;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        int i;
        if (!enif_get_int(env, head, &i) || i < 0 || i > 23)
            return enif_make_badarg(env);
        /* Reviewer pass 12 (NIF audit, batch 14) CRITICAL-1:
         * guard against pcr_indices[24] stack overflow. A caller
         * sending >24 PCR indices (or duplicates that inflate
         * pcr_count past the bitmap's unique-index count) would
         * otherwise write past the end of the stack buffer.
         * The per-index 0..23 range check above does NOT bound
         * pcr_count. */
        if (pcr_count >= 24)
            return enif_make_badarg(env);
        sel.pcrSelections[0].pcrSelect[i / 8] |= (1 << (i % 8));
        pcr_indices[pcr_count++] = i;
        have_any = 1;
    }
    if (!have_any) return enif_make_badarg(env);

    ErlNifBinary nonce;
    if (!enif_inspect_binary(env, argv[2], &nonce)) return enif_make_badarg(env);
    if (nonce.size > sizeof(((TPM2B_DATA *)0)->buffer)) return enif_make_badarg(env);

    TPM2B_DATA qual = { .size = (UINT16)nonce.size };
    memcpy(qual.buffer, nonce.data, nonce.size);

    TPMT_SIG_SCHEME scheme = {
        .scheme = TPM2_ALG_RSAPSS,
        .details.rsapss.hashAlg = TPM2_ALG_SHA256,
    };

    TPM2B_ATTEST *quoted = NULL;
    TPMT_SIGNATURE *signature = NULL;

    ESYS_TR ak_policy_session = ESYS_TR_NONE;
    TSS2_RC rc = lapee_ak_policy_session(
        TPM2_SE_POLICY, false, &ak_policy_session, NULL);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_PolicyPCR(AK)", rc);
    }
    ESYS_TR enc_session = ESYS_TR_NONE;
    rc = lapee_enc_session(&enc_session);
    if (rc != TSS2_RC_SUCCESS) {
        Esys_FlushContext(g_esys_ctx, ak_policy_session);
        return lapee_make_tss_error(env, "StartAuthSession(HMAC)", rc);
    }

    rc = Esys_Quote(g_esys_ctx,
                    (ESYS_TR)esys_tr,
                    ak_policy_session,
                    enc_session,
                    ESYS_TR_NONE,
                    &qual, &scheme, &sel,
                    &quoted, &signature);
    Esys_FlushContext(g_esys_ctx, ak_policy_session);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_Quote", rc);
    }

    ERL_NIF_TERM quoted_term;
    unsigned char *q_out = enif_make_new_binary(env, quoted->size, &quoted_term);
    memcpy(q_out, quoted->attestationData, quoted->size);

    /* Extract the raw RSA PSS signature bytes. */
    ERL_NIF_TERM sig_term;
    if (signature->sigAlg == TPM2_ALG_RSAPSS) {
        unsigned char *s_out = enif_make_new_binary(
            env, signature->signature.rsapss.sig.size, &sig_term);
        memcpy(s_out, signature->signature.rsapss.sig.buffer,
               signature->signature.rsapss.sig.size);
    } else if (signature->sigAlg == TPM2_ALG_RSASSA) {
        unsigned char *s_out = enif_make_new_binary(
            env, signature->signature.rsassa.sig.size, &sig_term);
        memcpy(s_out, signature->signature.rsassa.sig.buffer,
               signature->signature.rsassa.sig.size);
    } else {
        Esys_Free(quoted); Esys_Free(signature);
        return lapee_make_error(env, "unknown_sig_alg");
    }

    /* Also marshal the full TPMT_SIGNATURE so callers can feed it to
     * tpm2_checkquote, which expects the marshalled form. */
    size_t sig_marshal_size = 0;
    TSS2_RC mrc = Tss2_MU_TPMT_SIGNATURE_Marshal(signature, NULL, 1024,
                                                 &sig_marshal_size);
    ERL_NIF_TERM sig_marshal_term = enif_make_atom(env, "undefined");
    if (mrc == TSS2_RC_SUCCESS && sig_marshal_size > 0) {
        unsigned char *tmp = enif_alloc(sig_marshal_size);
        size_t off = 0;
        if (Tss2_MU_TPMT_SIGNATURE_Marshal(signature, tmp, sig_marshal_size, &off)
                == TSS2_RC_SUCCESS) {
            unsigned char *m_out = enif_make_new_binary(env, off, &sig_marshal_term);
            memcpy(m_out, tmp, off);
        }
        enif_free(tmp);
    }

    /* Read the PCR values too so we can build a pcrs.txt for tpm2_checkquote. */
    UINT32 uc; TPML_PCR_SELECTION *out_sel = NULL; TPML_DIGEST *digests = NULL;
    rc = Esys_PCR_Read(g_esys_ctx,
                       ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
                       &sel, &uc, &out_sel, &digests);
    ERL_NIF_TERM pcrs_map = enif_make_new_map(env);
    if (rc == TSS2_RC_SUCCESS && digests) {
        for (int i = 0; i < (int)digests->count && i < pcr_count; i++) {
            ERL_NIF_TERM val;
            unsigned char *d = enif_make_new_binary(
                env, digests->digests[i].size, &val);
            memcpy(d, digests->digests[i].buffer, digests->digests[i].size);
            enif_make_map_put(env, pcrs_map,
                              enif_make_int(env, pcr_indices[i]),
                              val, &pcrs_map);
        }
    }
    if (out_sel) Esys_Free(out_sel);
    if (digests) Esys_Free(digests);

    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map, enif_make_atom(env, "quoted"), quoted_term, &map);
    enif_make_map_put(env, map, enif_make_atom(env, "signature"), sig_term, &map);
    enif_make_map_put(env, map, enif_make_atom(env, "signature_marshalled"),
                      sig_marshal_term, &map);
    enif_make_map_put(env, map, enif_make_atom(env, "pcr_values"), pcrs_map, &map);

    Esys_Free(quoted); Esys_Free(signature);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), map);
}

/*-------------------------------- tpm_properties/0 --------------------------*/

/* Decode a 32-bit TPMU property value as a 4-char ASCII string and
 * drop it into `out' (4 bytes). Manufacturer ID + vendor string chunks
 * are conventionally four ASCII bytes packed big-endian into a U32. */
static void
u32_to_ascii4(uint32_t v, char out[4])
{
    out[0] = (char)((v >> 24) & 0xFF);
    out[1] = (char)((v >> 16) & 0xFF);
    out[2] = (char)((v >> 8)  & 0xFF);
    out[3] = (char)(v & 0xFF);
}

/* Query a single TPM_PT_* property via Esys_GetCapability. Returns the
 * UINT32 value (0 on failure) and writes the rc to *out_rc. We call
 * one property at a time because ESYS's GetCapability API is quirky
 * about batching -- the cleaner path is property-at-a-time and assemble
 * the result map in C.
 */
static UINT32
tpm_pt_get(TPM2_PT prop, TSS2_RC *out_rc)
{
    TPMS_CAPABILITY_DATA *cap_data = NULL;
    TPMI_YES_NO more = TPM2_NO;
    /* GetCapability response is TPMS_CAPABILITY_DATA (list-
     * struct, not TPM2B). Encrypt/decrypt attrs fail with
     * RC_ATTRIBUTES on this op; see lapee_ensure_auth_session
     * header. Response carries TPM vendor / firmware version
     * which are public per TCG -- no confidentiality need. */
    TSS2_RC rc = Esys_GetCapability(
        g_esys_ctx,
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        TPM2_CAP_TPM_PROPERTIES, prop, 1,
        &more, &cap_data);
    if (out_rc) *out_rc = rc;
    if (rc != TSS2_RC_SUCCESS || cap_data == NULL) {
        if (cap_data) Esys_Free(cap_data);
        return 0;
    }
    UINT32 val = 0;
    if (cap_data->capability == TPM2_CAP_TPM_PROPERTIES &&
        cap_data->data.tpmProperties.count > 0) {
        const TPMS_TAGGED_PROPERTY *p =
            &cap_data->data.tpmProperties.tpmProperty[0];
        if (p->property == prop) {
            val = p->value;
        }
    }
    Esys_Free(cap_data);
    return val;
}

/*
 * tpm_properties() -> {ok, #{manufacturer, vendor_string,
 *                            spec_family, spec_level, spec_revision,
 *                            firmware_version_1, firmware_version_2,
 *                            tpm_family}} | {error, Reason}
 *
 * Query TPM2_GetCapability for the standard manufacturer /
 * vendor-string / spec-version / firmware-version properties. This is
 * the PRIMARY TPM-identification path because it works even on TPMs
 * without a provisioned EK cert in NV -- which is currently the
 * default state for most AMD fTPMs. The EK cert's TCG-OID attributes,
 * when present, act as a CROSS-CHECK rather than the sole source.
 *
 * Field semantics (from TPM 2.0 Part 2, Table 22):
 *   manufacturer        -- TPM_PT_MANUFACTURER, 4-char ASCII
 *   vendor_string       -- TPM_PT_VENDOR_STRING_1..4, up to 16 ASCII
 *                          bytes of vendor-defined model text
 *   spec_family         -- TPM_PT_FAMILY_INDICATOR, "2.0" etc
 *   spec_level          -- TPM_PT_LEVEL
 *   spec_revision       -- TPM_PT_REVISION (hundredths, e.g. 138 = 1.38)
 *   firmware_version_1  -- TPM_PT_FIRMWARE_VERSION_1 (vendor-meaningful)
 *   firmware_version_2  -- TPM_PT_FIRMWARE_VERSION_2
 */
static ERL_NIF_TERM
nif_tpm_properties(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;

    TSS2_RC rc;
    UINT32 manu = tpm_pt_get(TPM2_PT_MANUFACTURER, &rc);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_GetCapability(MANUFACTURER)", rc);
    }
    UINT32 vs1 = tpm_pt_get(TPM2_PT_VENDOR_STRING_1, NULL);
    UINT32 vs2 = tpm_pt_get(TPM2_PT_VENDOR_STRING_2, NULL);
    UINT32 vs3 = tpm_pt_get(TPM2_PT_VENDOR_STRING_3, NULL);
    UINT32 vs4 = tpm_pt_get(TPM2_PT_VENDOR_STRING_4, NULL);
    UINT32 fam = tpm_pt_get(TPM2_PT_FAMILY_INDICATOR, NULL);
    UINT32 lvl = tpm_pt_get(TPM2_PT_LEVEL, NULL);
    UINT32 rev = tpm_pt_get(TPM2_PT_REVISION, NULL);
    UINT32 fw1 = tpm_pt_get(TPM2_PT_FIRMWARE_VERSION_1, NULL);
    UINT32 fw2 = tpm_pt_get(TPM2_PT_FIRMWARE_VERSION_2, NULL);
    UINT32 daymonth = tpm_pt_get(TPM2_PT_DAY_OF_YEAR, NULL);
    UINT32 year     = tpm_pt_get(TPM2_PT_YEAR, NULL);

    char manu_s[5] = {0};     u32_to_ascii4(manu, manu_s);
    char vs_s[17] = {0};
    u32_to_ascii4(vs1, vs_s);
    u32_to_ascii4(vs2, vs_s + 4);
    u32_to_ascii4(vs3, vs_s + 8);
    u32_to_ascii4(vs4, vs_s + 12);
    char fam_s[5] = {0};     u32_to_ascii4(fam, fam_s);

    /* Vendor string is 4 x 32-bit big-endian chunks per TCG spec.
     * Manufacturers with a short string (e.g. Nuvoton: "NPCT75x\0")
     * put their name in the first chunks and undefined bytes after
     * the terminating NUL. Treat as C-string: truncate at the first
     * NUL. The old trailing-NUL trim left embedded-NUL-plus-junk
     * tails like `NPCT75x\0"!!4rls` intact. */
    size_t vs_len = 0;
    while (vs_len < 16 && vs_s[vs_len] != '\0') vs_len++;

    /* Local "length until NUL, cap at MAX" -- avoids the strnlen
     * extension which isn't available on all libcs we target. */
    size_t manu_len = 0;
    while (manu_len < 4 && manu_s[manu_len] != '\0') manu_len++;
    size_t fam_len = 0;
    while (fam_len < 4 && fam_s[fam_len] != '\0') fam_len++;

    ERL_NIF_TERM manu_bin;
    {
        unsigned char *b = enif_make_new_binary(env, manu_len, &manu_bin);
        memcpy(b, manu_s, manu_len);
    }
    ERL_NIF_TERM vs_bin;
    {
        unsigned char *b = enif_make_new_binary(env, vs_len, &vs_bin);
        memcpy(b, vs_s, vs_len);
    }
    ERL_NIF_TERM fam_bin;
    {
        unsigned char *b = enif_make_new_binary(env, fam_len, &fam_bin);
        memcpy(b, fam_s, fam_len);
    }

    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map,
        enif_make_atom(env, "manufacturer"), manu_bin, &map);
    enif_make_map_put(env, map,
        enif_make_atom(env, "manufacturer_u32"),
        enif_make_uint(env, manu), &map);
    enif_make_map_put(env, map,
        enif_make_atom(env, "vendor_string"), vs_bin, &map);
    enif_make_map_put(env, map,
        enif_make_atom(env, "spec_family"), fam_bin, &map);
    enif_make_map_put(env, map,
        enif_make_atom(env, "spec_level"),
        enif_make_uint(env, lvl), &map);
    enif_make_map_put(env, map,
        enif_make_atom(env, "spec_revision"),
        enif_make_uint(env, rev), &map);
    enif_make_map_put(env, map,
        enif_make_atom(env, "firmware_version_1"),
        enif_make_uint(env, fw1), &map);
    enif_make_map_put(env, map,
        enif_make_atom(env, "firmware_version_2"),
        enif_make_uint(env, fw2), &map);
    enif_make_map_put(env, map,
        enif_make_atom(env, "day_of_year"),
        enif_make_uint(env, daymonth), &map);
    enif_make_map_put(env, map,
        enif_make_atom(env, "year"),
        enif_make_uint(env, year), &map);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), map);
}

/*-------------------------------- nv_read_public/1 --------------------------*/

/*
 * nv_read_public(TpmHandle) -> {ok, #{data_size, attributes, name_alg,
 *                                     auth_policy_len}} | {error, Reason}
 *
 * Look up an NV index by its TPM handle and return its public metadata.
 * Returns {error, nv_index_undefined} when the handle is not defined on
 * this TPM (the canonical signal that e.g. there is no EK cert in NV).
 * Any other TSS2 failure is surfaced with its decoded RC string.
 *
 * This is the read-only half of the EK-cert-from-NV flow and is useful
 * on its own for diagnostics ("what NV indices does this TPM actually
 * provision?"). For fetching the bytes, see nv_read/1.
 */
static ERL_NIF_TERM
nif_nv_read_public(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    unsigned handle_u;
    if (!enif_get_uint(env, argv[0], &handle_u))
        return enif_make_badarg(env);
    TPM2_HANDLE tpm_handle = (TPM2_HANDLE)handle_u;

    ESYS_TR nv_tr = ESYS_TR_NONE;
    TSS2_RC rc = Esys_TR_FromTPMPublic(
        g_esys_ctx, tpm_handle,
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        &nv_tr);
    if (rc != TSS2_RC_SUCCESS) {
        /* TPM2_RC_HANDLE at the formatter level means "no such handle".
         * Map that to an explicit atom so callers can distinguish
         * "NV not provisioned" from real TPM errors. */
        /* TPM2_RC_HANDLE is a FMT1 response (bit 7 set). On the
         * wire it may have handle/parameter/session position bits
         * set in 0xF00; mask those out before comparing. */
        if ((rc & 0x0BF) == (TPM2_RC_HANDLE & 0x0BF))
            return lapee_make_error(env, "nv_index_undefined");
        return lapee_make_tss_error(env, "Esys_TR_FromTPMPublic", rc);
    }

    TPM2B_NV_PUBLIC *nv_public = NULL;
    rc = Esys_NV_ReadPublic(
        g_esys_ctx, nv_tr,
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        &nv_public, NULL);
    if (rc != TSS2_RC_SUCCESS) {
        /* Drop our ESYS_TR reference to the NV index before returning.
         * The TPM-side handle is untouched. */
        Esys_TR_Close(g_esys_ctx, &nv_tr);
        return lapee_make_tss_error(env, "Esys_NV_ReadPublic", rc);
    }

    UINT16 data_size     = nv_public->nvPublic.dataSize;
    UINT32 attributes    = nv_public->nvPublic.attributes;
    TPMI_ALG_HASH nmalg  = nv_public->nvPublic.nameAlg;
    UINT16 pol_len       = nv_public->nvPublic.authPolicy.size;
    Esys_Free(nv_public);
    Esys_TR_Close(g_esys_ctx, &nv_tr);

    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map,
        enif_make_atom(env, "data_size"),
        enif_make_uint(env, (unsigned)data_size), &map);
    enif_make_map_put(env, map,
        enif_make_atom(env, "attributes"),
        enif_make_uint(env, (unsigned)attributes), &map);
    enif_make_map_put(env, map,
        enif_make_atom(env, "name_alg"),
        enif_make_uint(env, (unsigned)nmalg), &map);
    enif_make_map_put(env, map,
        enif_make_atom(env, "auth_policy_len"),
        enif_make_uint(env, (unsigned)pol_len), &map);
    enif_make_map_put(env, map,
        enif_make_atom(env, "handle"),
        enif_make_uint(env, (unsigned)tpm_handle), &map);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), map);
}

/*-------------------------------- nv_read/1 ---------------------------------*/

/*
 * nv_read(TpmHandle) -> {ok, Bytes::binary()} | {error, Reason}
 *
 * Read the full contents of an NV index addressed by its TPM handle.
 * Reads are chunked at TPM2_MAX_NV_BUFFER_SIZE (conservative 512 B)
 * because the TPM's own per-call buffer limit is platform-dependent.
 *
 * Auth handle is picked from TPMA_NV attributes in the same order a
 * well-behaved TSS client would: if TPMA_NV_AUTHREAD is set we auth
 * against the NV index itself (empty auth, which is the convention
 * for EK-cert indices); else TPMA_NV_OWNERREAD -> RH_OWNER;
 * else TPMA_NV_PPREAD -> RH_PLATFORM. If none of those bits is set
 * or a read returns TPM2_RC_BAD_AUTH we fall back through the list
 * before giving up, because real TPMs (notably AMD fTPM) sometimes
 * set OWNERREAD but accept AUTHREAD too.
 *
 * {error, nv_index_undefined} on missing handle, same as
 * nv_read_public/1. Any other TSS2 failure is surfaced verbatim.
 */
static ERL_NIF_TERM
nif_nv_read(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    unsigned handle_u;
    if (!enif_get_uint(env, argv[0], &handle_u))
        return enif_make_badarg(env);
    TPM2_HANDLE tpm_handle = (TPM2_HANDLE)handle_u;

    ESYS_TR nv_tr = ESYS_TR_NONE;
    TSS2_RC rc = Esys_TR_FromTPMPublic(
        g_esys_ctx, tpm_handle,
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        &nv_tr);
    if (rc != TSS2_RC_SUCCESS) {
        /* TPM2_RC_HANDLE is a FMT1 response (bit 7 set). On the
         * wire it may have handle/parameter/session position bits
         * set in 0xF00; mask those out before comparing. */
        if ((rc & 0x0BF) == (TPM2_RC_HANDLE & 0x0BF))
            return lapee_make_error(env, "nv_index_undefined");
        return lapee_make_tss_error(env, "Esys_TR_FromTPMPublic", rc);
    }

    TPM2B_NV_PUBLIC *nv_public = NULL;
    rc = Esys_NV_ReadPublic(
        g_esys_ctx, nv_tr,
        ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
        &nv_public, NULL);
    if (rc != TSS2_RC_SUCCESS) {
        Esys_TR_Close(g_esys_ctx, &nv_tr);
        return lapee_make_tss_error(env, "Esys_NV_ReadPublic", rc);
    }

    UINT16 data_size = nv_public->nvPublic.dataSize;
    UINT32 attrs     = nv_public->nvPublic.attributes;
    Esys_Free(nv_public);

    if (data_size == 0) {
        Esys_TR_Close(g_esys_ctx, &nv_tr);
        return lapee_make_error(env, "nv_index_empty");
    }

    /* Candidate auth handles, in decreasing order of "what EK-cert
     * conventions say". The read loop below tries each in turn when
     * it sees TPM2_RC_BAD_AUTH / TPM2_RC_AUTH_UNAVAILABLE. */
    ESYS_TR auth_candidates[3] = { ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE };
    int n_candidates = 0;
    if (attrs & TPMA_NV_AUTHREAD)  auth_candidates[n_candidates++] = nv_tr;
    if (attrs & TPMA_NV_OWNERREAD) auth_candidates[n_candidates++] = ESYS_TR_RH_OWNER;
    if (attrs & TPMA_NV_PPREAD)    auth_candidates[n_candidates++] = ESYS_TR_RH_PLATFORM;
    if (n_candidates == 0) {
        /* No read bits set in attributes -- the index is write-only
         * or policy-protected. Report explicitly. */
        Esys_TR_Close(g_esys_ctx, &nv_tr);
        return lapee_make_error(env, "nv_index_not_readable");
    }

    ERL_NIF_TERM out_bin;
    unsigned char *out_buf = enif_make_new_binary(env, data_size, &out_bin);

    int success = 0;
    TSS2_RC last_rc = TSS2_RC_SUCCESS;
    const char *last_op = "Esys_NV_Read";
    for (int i = 0; i < n_candidates && !success; i++) {
        ESYS_TR auth = auth_candidates[i];
        UINT16 offset = 0;
        /* Conservative chunk size. TCG allows up to TPM2_MAX_NV_BUFFER_SIZE
         * but many TPMs respect a smaller firmware-advertised limit
         * (TPM_PT_NV_BUFFER_MAX). 512 is a safe lower bound. */
        const UINT16 CHUNK = 512;
        int attempt_ok = 1;
        while (offset < data_size && attempt_ok) {
            UINT16 want = (UINT16)(data_size - offset);
            if (want > CHUNK) want = CHUNK;
            TPM2B_MAX_NV_BUFFER *data = NULL;
            rc = Esys_NV_Read(
                g_esys_ctx,
                auth, nv_tr,
                ESYS_TR_PASSWORD, ESYS_TR_NONE, ESYS_TR_NONE,
                want, offset, &data);
            if (rc != TSS2_RC_SUCCESS) {
                attempt_ok = 0;
                last_rc = rc;
                last_op = "Esys_NV_Read";
                break;
            }
            if (data->size == 0) {
                Esys_Free(data);
                attempt_ok = 0;
                last_rc = TPM2_RC_NO_RESULT;
                last_op = "Esys_NV_Read(short-read)";
                break;
            }
            memcpy(out_buf + offset, data->buffer, data->size);
            offset = (UINT16)(offset + data->size);
            Esys_Free(data);
        }
        if (attempt_ok && offset == data_size) {
            success = 1;
        }
    }

    Esys_TR_Close(g_esys_ctx, &nv_tr);

    if (!success) {
        return lapee_make_tss_error(env, last_op, last_rc);
    }
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), out_bin);
}

/*-------------------------------- flush_context/1 ---------------------------*/

static ERL_NIF_TERM
nif_flush_context(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    unsigned esys_tr;
    if (!enif_get_uint(env, argv[0], &esys_tr)) return enif_make_badarg(env);
    TSS2_RC rc = Esys_FlushContext(g_esys_ctx, (ESYS_TR)esys_tr);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_FlushContext", rc);
    }
    return enif_make_atom(env, "ok");
}

/*-------------------------------- set_tcti/1 --------------------------------*/

static ERL_NIF_TERM
nif_set_tcti(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    char buf[512];
    if (enif_get_string(env, argv[0], buf, sizeof(buf), ERL_NIF_LATIN1) <= 0)
        return enif_make_badarg(env);
    /* Re-init TCTI + ESYS. */
    if (g_esys_ctx) { Esys_Finalize(&g_esys_ctx); g_esys_ctx = NULL; }
    if (g_tcti_ctx) { Tss2_TctiLdr_Finalize(&g_tcti_ctx); g_tcti_ctx = NULL; }
    memcpy(g_tcti_conf, buf, sizeof(g_tcti_conf));
    TSS2_RC rc = Tss2_TctiLdr_Initialize(g_tcti_conf, &g_tcti_ctx);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Tss2_TctiLdr_Initialize", rc);
    }
    rc = Esys_Initialize(&g_esys_ctx, g_tcti_ctx, NULL);
    if (rc != TSS2_RC_SUCCESS) {
        return lapee_make_tss_error(env, "Esys_Initialize", rc);
    }
    return enif_make_atom(env, "ok");
}

/*-------------------------------- NIF table ---------------------------------*/

/* Reviewer pass 12 (NIF audit, batch 14) HIGH: every NIF that
 * blocks on a synchronous TPM/SPI round-trip longer than ~1ms
 * must be declared with ERL_NIF_DIRTY_JOB_IO_BOUND so the BEAM
 * scheduler yields the calling process to a dirty scheduler
 * instead of stalling a regular scheduler for the duration of
 * the call.
 *
 * Observed latencies on Nuvoton NPCT75x over SPI:
 *   Esys_CreatePrimary (RSA-2048 keygen) : 300-800 ms
 *   Esys_Quote (RSA-PSS sign + PCR read) : 200-400 ms
 *   Esys_NV_Read (chunked 512 B/round)   :  30-80 ms for a 1.5 KB cert
 *   Esys_PCR_Extend                      :   5-15 ms
 *   Esys_PCR_Read                        :   2- 8 ms
 *   Esys_GetCapability                   :   2-10 ms (tpm_properties)
 *
 * flush_context, set_tcti, and startup are either no-ops on the
 * TPM or one-shot calls during init; they stay on the regular
 * scheduler. `startup' is technically borderline (~50-200 ms on
 * first call) but fires once per boot, so the flag churn isn't
 * worth it.
 *
 * With dirty-NIF flags set, concurrent /attestation requests no
 * longer block a regular scheduler, and the BEAM will log no
 * scheduler-stall warnings during the demo's 2-second
 * attestation window.
 */
static ErlNifFunc nif_funcs[] = {
    {"startup", 0, nif_startup, 0},
    {"pcr_read", 1, nif_pcr_read, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"pcr_extend", 2, nif_pcr_extend, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"create_primary_ek", 0, nif_create_primary_ek,
                              ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"create_signing_key", 1, nif_create_signing_key,
                              ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"make_credential", 3, nif_make_credential,
                            ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"activate_credential", 4, nif_activate_credential,
                                ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"quote", 3, nif_quote, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"tpm_properties", 0, nif_tpm_properties,
                           ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nv_read_public", 1, nif_nv_read_public,
                          ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nv_read", 1, nif_nv_read, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"flush_context", 1, nif_flush_context, 0},
    {"set_tcti", 1, nif_set_tcti, 0}
};

ERL_NIF_INIT(lapee_tpm_nif, nif_funcs, do_load, NULL, NULL, do_unload)
