#include "VoicePanelORTBridge.h"

#include <onnxruntime_c_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct VPORTRuntime {
    const OrtApi *api;
    OrtEnv *environment;
    OrtSessionOptions *session_options;
    OrtSession *encoder;
    OrtSession *decoder;
    OrtMemoryInfo *memory_info;
};

struct VPORTHiddenState {
    const OrtApi *api;
    OrtValue *value;
};

static void vp_copy_error(char *buffer, size_t size, const char *message) {
    if (buffer == NULL || size == 0) {
        return;
    }
    if (message == NULL) {
        message = "Unknown ONNX Runtime error.";
    }
    snprintf(buffer, size, "%s", message);
}

static int vp_status_ok(
    const OrtApi *api,
    OrtStatus *status,
    char *error_buffer,
    size_t error_buffer_size
) {
    if (status == NULL) {
        return 1;
    }
    vp_copy_error(error_buffer, error_buffer_size, api->GetErrorMessage(status));
    api->ReleaseStatus(status);
    return 0;
}

static void vp_release_runtime(VPORTRuntime *runtime) {
    if (runtime == NULL || runtime->api == NULL) {
        free(runtime);
        return;
    }
    if (runtime->decoder != NULL) runtime->api->ReleaseSession(runtime->decoder);
    if (runtime->encoder != NULL) runtime->api->ReleaseSession(runtime->encoder);
    if (runtime->memory_info != NULL) runtime->api->ReleaseMemoryInfo(runtime->memory_info);
    if (runtime->session_options != NULL) runtime->api->ReleaseSessionOptions(runtime->session_options);
    if (runtime->environment != NULL) runtime->api->ReleaseEnv(runtime->environment);
    free(runtime);
}

VPORTRuntime *vp_ort_runtime_create(
    const char *encoder_path,
    const char *decoder_path,
    int32_t thread_count,
    char *error_buffer,
    size_t error_buffer_size
) {
    const OrtApi *api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (api == NULL) {
        vp_copy_error(error_buffer, error_buffer_size, "ONNX Runtime API is unavailable.");
        return NULL;
    }

    VPORTRuntime *runtime = (VPORTRuntime *)calloc(1, sizeof(VPORTRuntime));
    if (runtime == NULL) {
        vp_copy_error(error_buffer, error_buffer_size, "Could not allocate the ONNX Runtime bridge.");
        return NULL;
    }
    runtime->api = api;

    if (!vp_status_ok(api, api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "VoicePanelTextCorrection", &runtime->environment), error_buffer, error_buffer_size)) {
        vp_release_runtime(runtime);
        return NULL;
    }
    if (!vp_status_ok(api, api->CreateSessionOptions(&runtime->session_options), error_buffer, error_buffer_size)) {
        vp_release_runtime(runtime);
        return NULL;
    }
    if (!vp_status_ok(api, api->SetIntraOpNumThreads(runtime->session_options, thread_count > 0 ? thread_count : 1), error_buffer, error_buffer_size)) {
        vp_release_runtime(runtime);
        return NULL;
    }
    if (!vp_status_ok(api, api->SetSessionGraphOptimizationLevel(runtime->session_options, ORT_ENABLE_ALL), error_buffer, error_buffer_size)) {
        vp_release_runtime(runtime);
        return NULL;
    }
    if (!vp_status_ok(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &runtime->memory_info), error_buffer, error_buffer_size)) {
        vp_release_runtime(runtime);
        return NULL;
    }
    if (!vp_status_ok(api, api->CreateSession(runtime->environment, encoder_path, runtime->session_options, &runtime->encoder), error_buffer, error_buffer_size)) {
        vp_release_runtime(runtime);
        return NULL;
    }
    if (!vp_status_ok(api, api->CreateSession(runtime->environment, decoder_path, runtime->session_options, &runtime->decoder), error_buffer, error_buffer_size)) {
        vp_release_runtime(runtime);
        return NULL;
    }
    return runtime;
}

void vp_ort_runtime_destroy(VPORTRuntime *runtime) {
    vp_release_runtime(runtime);
}

VPORTHiddenState *vp_ort_encode(
    VPORTRuntime *runtime,
    const int64_t *input_ids,
    const int64_t *attention_mask,
    size_t token_count,
    char *error_buffer,
    size_t error_buffer_size
) {
    if (runtime == NULL || token_count == 0) {
        vp_copy_error(error_buffer, error_buffer_size, "The encoder received an empty token sequence.");
        return NULL;
    }

    int64_t shape[] = {1, (int64_t)token_count};
    OrtValue *ids_value = NULL;
    OrtValue *mask_value = NULL;
    if (!vp_status_ok(runtime->api, runtime->api->CreateTensorWithDataAsOrtValue(
            runtime->memory_info, (void *)input_ids, token_count * sizeof(int64_t), shape, 2,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &ids_value), error_buffer, error_buffer_size)) {
        return NULL;
    }
    if (!vp_status_ok(runtime->api, runtime->api->CreateTensorWithDataAsOrtValue(
            runtime->memory_info, (void *)attention_mask, token_count * sizeof(int64_t), shape, 2,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &mask_value), error_buffer, error_buffer_size)) {
        runtime->api->ReleaseValue(ids_value);
        return NULL;
    }

    const char *input_names[] = {"input_ids", "attention_mask"};
    const OrtValue *input_values[] = {ids_value, mask_value};
    const char *output_names[] = {"last_hidden_state"};
    OrtValue *output = NULL;
    OrtStatus *status = runtime->api->Run(
        runtime->encoder, NULL, input_names, input_values, 2, output_names, 1, &output);
    runtime->api->ReleaseValue(mask_value);
    runtime->api->ReleaseValue(ids_value);
    if (!vp_status_ok(runtime->api, status, error_buffer, error_buffer_size)) {
        return NULL;
    }

    VPORTHiddenState *hidden = (VPORTHiddenState *)calloc(1, sizeof(VPORTHiddenState));
    if (hidden == NULL) {
        runtime->api->ReleaseValue(output);
        vp_copy_error(error_buffer, error_buffer_size, "Could not retain the encoder output.");
        return NULL;
    }
    hidden->api = runtime->api;
    hidden->value = output;
    return hidden;
}

void vp_ort_hidden_state_destroy(VPORTHiddenState *hidden_state) {
    if (hidden_state == NULL) return;
    if (hidden_state->api != NULL && hidden_state->value != NULL) {
        hidden_state->api->ReleaseValue(hidden_state->value);
    }
    free(hidden_state);
}

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
) {
    if (runtime == NULL || hidden_state == NULL || hidden_state->value == NULL ||
        encoder_token_count == 0 || decoder_token_count == 0 || next_token == NULL) {
        vp_copy_error(error_buffer, error_buffer_size, "The decoder received incomplete input.");
        return 0;
    }

    int64_t decoder_shape[] = {1, (int64_t)decoder_token_count};
    int64_t mask_shape[] = {1, (int64_t)encoder_token_count};
    OrtValue *decoder_ids_value = NULL;
    OrtValue *mask_value = NULL;
    if (!vp_status_ok(runtime->api, runtime->api->CreateTensorWithDataAsOrtValue(
            runtime->memory_info, (void *)decoder_input_ids,
            decoder_token_count * sizeof(int64_t), decoder_shape, 2,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &decoder_ids_value), error_buffer, error_buffer_size)) {
        return 0;
    }
    if (!vp_status_ok(runtime->api, runtime->api->CreateTensorWithDataAsOrtValue(
            runtime->memory_info, (void *)encoder_attention_mask,
            encoder_token_count * sizeof(int64_t), mask_shape, 2,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &mask_value), error_buffer, error_buffer_size)) {
        runtime->api->ReleaseValue(decoder_ids_value);
        return 0;
    }

    const char *input_names[] = {"input_ids", "encoder_attention_mask", "encoder_hidden_states"};
    const OrtValue *input_values[] = {decoder_ids_value, mask_value, hidden_state->value};
    const char *output_names[] = {"logits"};
    OrtValue *logits = NULL;
    OrtStatus *status = runtime->api->Run(
        runtime->decoder, NULL, input_names, input_values, 3, output_names, 1, &logits);
    runtime->api->ReleaseValue(mask_value);
    runtime->api->ReleaseValue(decoder_ids_value);
    if (!vp_status_ok(runtime->api, status, error_buffer, error_buffer_size)) {
        return 0;
    }

    OrtTensorTypeAndShapeInfo *shape_info = NULL;
    size_t dimension_count = 0;
    int64_t dimensions[4] = {0, 0, 0, 0};
    float *logit_data = NULL;
    if (!vp_status_ok(runtime->api, runtime->api->GetTensorTypeAndShape(logits, &shape_info), error_buffer, error_buffer_size) ||
        !vp_status_ok(runtime->api, runtime->api->GetDimensionsCount(shape_info, &dimension_count), error_buffer, error_buffer_size) ||
        dimension_count < 2 || dimension_count > 4 ||
        !vp_status_ok(runtime->api, runtime->api->GetDimensions(shape_info, dimensions, dimension_count), error_buffer, error_buffer_size) ||
        !vp_status_ok(runtime->api, runtime->api->GetTensorMutableData(logits, (void **)&logit_data), error_buffer, error_buffer_size)) {
        if (shape_info != NULL) runtime->api->ReleaseTensorTypeAndShapeInfo(shape_info);
        runtime->api->ReleaseValue(logits);
        return 0;
    }

    const int64_t vocabulary_size = dimensions[dimension_count - 1];
    const int64_t sequence_length = dimensions[dimension_count - 2];
    if (vocabulary_size <= 0 || sequence_length <= 0 || logit_data == NULL) {
        runtime->api->ReleaseTensorTypeAndShapeInfo(shape_info);
        runtime->api->ReleaseValue(logits);
        vp_copy_error(error_buffer, error_buffer_size, "The decoder returned invalid logits.");
        return 0;
    }

    const float *last_logits = logit_data + (sequence_length - 1) * vocabulary_size;
    int64_t best_token = 0;
    float best_value = last_logits[0];
    for (int64_t index = 1; index < vocabulary_size; ++index) {
        if (last_logits[index] > best_value) {
            best_value = last_logits[index];
            best_token = index;
        }
    }
    *next_token = best_token;

    runtime->api->ReleaseTensorTypeAndShapeInfo(shape_info);
    runtime->api->ReleaseValue(logits);
    return 1;
}
