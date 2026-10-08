#include "VoicePanelCryptoCompat.h"

#include <openssl/evp.h>
#include <openssl/rand.h>
#include <string.h>

#define VP_GCM_NONCE_LENGTH 12
#define VP_GCM_TAG_LENGTH 16

static const EVP_CIPHER *vp_cipher_for_key_length(size_t key_length) {
    switch (key_length) {
    case 16:
        return EVP_aes_128_gcm();
    case 24:
        return EVP_aes_192_gcm();
    case 32:
        return EVP_aes_256_gcm();
    default:
        return NULL;
    }
}

int vp_aes_gcm_seal(
    const uint8_t *plaintext,
    size_t plaintext_length,
    const uint8_t *key,
    size_t key_length,
    uint8_t *output,
    size_t output_capacity,
    size_t *output_length
) {
    const EVP_CIPHER *cipher = vp_cipher_for_key_length(key_length);
    const size_t required = VP_GCM_NONCE_LENGTH + plaintext_length + VP_GCM_TAG_LENGTH;
    EVP_CIPHER_CTX *context = NULL;
    int written = 0;
    int final_written = 0;
    int result = 0;

    if (cipher == NULL || key == NULL || output == NULL || output_length == NULL ||
        output_capacity < required) {
        return 0;
    }

    if (RAND_bytes(output, VP_GCM_NONCE_LENGTH) != 1) {
        return 0;
    }

    context = EVP_CIPHER_CTX_new();
    if (context == NULL) {
        return 0;
    }

    if (EVP_EncryptInit_ex(context, cipher, NULL, NULL, NULL) != 1 ||
        EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_SET_IVLEN, VP_GCM_NONCE_LENGTH, NULL) != 1 ||
        EVP_EncryptInit_ex(context, NULL, NULL, key, output) != 1) {
        goto cleanup;
    }

    if (plaintext_length > 0 &&
        EVP_EncryptUpdate(
            context,
            output + VP_GCM_NONCE_LENGTH,
            &written,
            plaintext,
            (int)plaintext_length
        ) != 1) {
        goto cleanup;
    }

    if (EVP_EncryptFinal_ex(
            context,
            output + VP_GCM_NONCE_LENGTH + written,
            &final_written
        ) != 1) {
        goto cleanup;
    }

    if (EVP_CIPHER_CTX_ctrl(
            context,
            EVP_CTRL_GCM_GET_TAG,
            VP_GCM_TAG_LENGTH,
            output + VP_GCM_NONCE_LENGTH + plaintext_length
        ) != 1) {
        goto cleanup;
    }

    *output_length = required;
    result = 1;

cleanup:
    EVP_CIPHER_CTX_free(context);
    return result;
}

int vp_aes_gcm_open(
    const uint8_t *combined,
    size_t combined_length,
    const uint8_t *key,
    size_t key_length,
    uint8_t *plaintext,
    size_t plaintext_capacity,
    size_t *plaintext_length
) {
    const EVP_CIPHER *cipher = vp_cipher_for_key_length(key_length);
    const uint8_t *nonce;
    const uint8_t *ciphertext;
    const uint8_t *tag;
    size_t ciphertext_length;
    EVP_CIPHER_CTX *context = NULL;
    int written = 0;
    int final_written = 0;
    int result = 0;

    if (cipher == NULL || combined == NULL || key == NULL || plaintext_length == NULL ||
        combined_length < VP_GCM_NONCE_LENGTH + VP_GCM_TAG_LENGTH) {
        return 0;
    }

    ciphertext_length = combined_length - VP_GCM_NONCE_LENGTH - VP_GCM_TAG_LENGTH;
    if ((ciphertext_length > 0 && plaintext == NULL) || plaintext_capacity < ciphertext_length) {
        return 0;
    }

    nonce = combined;
    ciphertext = combined + VP_GCM_NONCE_LENGTH;
    tag = ciphertext + ciphertext_length;

    context = EVP_CIPHER_CTX_new();
    if (context == NULL) {
        return 0;
    }

    if (EVP_DecryptInit_ex(context, cipher, NULL, NULL, NULL) != 1 ||
        EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_SET_IVLEN, VP_GCM_NONCE_LENGTH, NULL) != 1 ||
        EVP_DecryptInit_ex(context, NULL, NULL, key, nonce) != 1) {
        goto cleanup;
    }

    if (ciphertext_length > 0 &&
        EVP_DecryptUpdate(
            context,
            plaintext,
            &written,
            ciphertext,
            (int)ciphertext_length
        ) != 1) {
        goto cleanup;
    }

    if (EVP_CIPHER_CTX_ctrl(
            context,
            EVP_CTRL_GCM_SET_TAG,
            VP_GCM_TAG_LENGTH,
            (void *)tag
        ) != 1) {
        goto cleanup;
    }

    if (EVP_DecryptFinal_ex(context, plaintext + written, &final_written) != 1) {
        goto cleanup;
    }

    *plaintext_length = (size_t)(written + final_written);
    result = 1;

cleanup:
    EVP_CIPHER_CTX_free(context);
    return result;
}
