#ifndef VOICE_PANEL_ORT_BRIDGE_H
#define VOICE_PANEL_ORT_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VPORTRuntime VPORTRuntime;
typedef struct VPORTHiddenState VPORTHiddenState;

VPORTRuntime *vp_ort_runtime_create(
    const char *encoder_path,
    const char *decoder_path,
    int32_t thread_count,
    char *error_buffer,
    size_t error_buffer_size
);

void vp_ort_runtime_destroy(VPORTRuntime *runtime);

VPORTHiddenState *vp_ort_encode(
    VPORTRuntime *runtime,
    const int64_t *input_ids,
    const int64_t *attention_mask,
    size_t token_count,
    char *error_buffer,
    size_t error_buffer_size
);

void vp_ort_hidden_state_destroy(VPORTHiddenState *hidden_state);

int32_t vp_ort_decode_next_token(
    VPORTRuntime *runtime,
    const VPORTHiddenState *hidden_state,
    const int64_t *encoder_attention_mask,
    size_t encoder_token_count,
    const int64_t *decoder_input_ids,
    size_t decoder_token_count,
    int64_t *next_token,
    char *error_buffer,
    size_t error_buffer_size
);

#ifdef __cplusplus
}
#endif

#endif
