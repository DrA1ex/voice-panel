#ifndef VOICE_PANEL_CRYPTO_COMPAT_H
#define VOICE_PANEL_CRYPTO_COMPAT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int vp_aes_gcm_seal(
    const uint8_t *plaintext,
    size_t plaintext_length,
    const uint8_t *key,
    size_t key_length,
    uint8_t *output,
    size_t output_capacity,
    size_t *output_length
);

int vp_aes_gcm_open(
    const uint8_t *combined,
    size_t combined_length,
    const uint8_t *key,
    size_t key_length,
    uint8_t *plaintext,
    size_t plaintext_capacity,
    size_t *plaintext_length
);

#ifdef __cplusplus
}
#endif

#endif
