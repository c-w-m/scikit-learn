# Author: Nicolas Hug

cimport cython
from cython.parallel import prange
import numpy as np
cimport numpy as np

from libc.math cimport exp, log

from .common cimport Y_DTYPE_C
from .common cimport G_H_DTYPE_C

np.import_array()


def _update_gradients_least_squares(
        G_H_DTYPE_C [::1] gradients,  # OUT
        const Y_DTYPE_C [::1] y_true,  # IN
        const Y_DTYPE_C [::1] raw_predictions, # IN
        int n_threads,  # IN
):

    cdef:
        int n_samples
        int i

    n_samples = raw_predictions.shape[0]
    for i in prange(n_samples, schedule='static', nogil=True, num_threads=n_threads):
        # Note: a more correct expression is 2 * (raw_predictions - y_true)
        # but since we use 1 for the constant hessian value (and not 2) this
        # is strictly equivalent for the leaves values.
        gradients[i] = raw_predictions[i] - y_true[i]


def _update_gradients_hessians_least_squares(
        G_H_DTYPE_C [::1] gradients,  # OUT
        G_H_DTYPE_C [::1] hessians,  # OUT
        const Y_DTYPE_C [::1] y_true,  # IN
        const Y_DTYPE_C [::1] raw_predictions,  # IN
        const Y_DTYPE_C [::1] sample_weight,  # IN
        int n_threads,  # IN
):

    cdef:
        int n_samples
        int i

    n_samples = raw_predictions.shape[0]
    for i in prange(n_samples, schedule='static', nogil=True, num_threads=n_threads):
        # Note: a more correct exp is 2 * (raw_predictions - y_true) * sample_weight
        # but since we use 1 for the constant hessian value (and not 2) this
        # is strictly equivalent for the leaves values.
        gradients[i] = (raw_predictions[i] - y_true[i]) * sample_weight[i]
        hessians[i] = sample_weight[i]


def _update_gradients_hessians_least_absolute_deviation(
        G_H_DTYPE_C [::1] gradients,  # OUT
        G_H_DTYPE_C [::1] hessians,  # OUT
        const Y_DTYPE_C [::1] y_true,  # IN
        const Y_DTYPE_C [::1] raw_predictions,  # IN
        const Y_DTYPE_C [::1] sample_weight, # IN
        int n_threads,  # IN
):
    cdef:
        int n_samples
        int i

    n_samples = raw_predictions.shape[0]
    for i in prange(n_samples, schedule='static', nogil=True, num_threads=n_threads):
        # gradient = sign(raw_predicition - y_pred) * sample_weight
        gradients[i] = sample_weight[i] * (2 *
                        (y_true[i] - raw_predictions[i] < 0) - 1)
        hessians[i] = sample_weight[i]


def _update_gradients_least_absolute_deviation(
        G_H_DTYPE_C [::1] gradients,  # OUT
        const Y_DTYPE_C [::1] y_true,  # IN
        const Y_DTYPE_C [::1] raw_predictions,  # IN
        int n_threads,  # IN
):
    cdef:
        int n_samples
        int i

    n_samples = raw_predictions.shape[0]
    for i in prange(n_samples, schedule='static', nogil=True, num_threads=n_threads):
        # gradient = sign(raw_predicition - y_pred)
        gradients[i] = 2 * (y_true[i] - raw_predictions[i] < 0) - 1


def _update_gradients_hessians_poisson(
        G_H_DTYPE_C [::1] gradients,  # OUT
        G_H_DTYPE_C [::1] hessians,  # OUT
        const Y_DTYPE_C [::1] y_true,  # IN
        const Y_DTYPE_C [::1] raw_predictions,  # IN
        const Y_DTYPE_C [::1] sample_weight, # IN
        int n_threads,  # IN
):
    cdef:
        int n_samples
        int i
        Y_DTYPE_C y_pred

    n_samples = raw_predictions.shape[0]
    if sample_weight is None:
        for i in prange(n_samples, schedule='static', nogil=True, num_threads=n_threads):
            # Note: We use only half of the deviance loss. Therefore, there is
            # no factor of 2.
            y_pred = exp(raw_predictions[i])
            gradients[i] = (y_pred - y_true[i])
            hessians[i] = y_pred
    else:
        for i in prange(n_samples, schedule='static', nogil=True, num_threads=n_threads):
            # Note: We use only half of the deviance loss. Therefore, there is
            # no factor of 2.
            y_pred = exp(raw_predictions[i])
            gradients[i] = (y_pred - y_true[i]) * sample_weight[i]
            hessians[i] = y_pred * sample_weight[i]


def _update_gradients_hessians_binary_crossentropy(
        G_H_DTYPE_C [::1] gradients,  # OUT
        G_H_DTYPE_C [::1] hessians,  # OUT
        const Y_DTYPE_C [::1] y_true,  # IN
        const Y_DTYPE_C [::1] raw_predictions,  # IN
        const Y_DTYPE_C [::1] sample_weight,  # IN
        int n_threads,  # IN
):
    cdef:
        int n_samples
        Y_DTYPE_C p_i  # proba that ith sample belongs to positive class
        int i

    n_samples = raw_predictions.shape[0]
    if sample_weight is None:
        for i in prange(n_samples, schedule='static', nogil=True, num_threads=n_threads):
            p_i = _cexpit(raw_predictions[i])
            gradients[i] = p_i - y_true[i]
            hessians[i] = p_i * (1. - p_i)
    else:
        for i in prange(n_samples, schedule='static', nogil=True, num_threads=n_threads):
            p_i = _cexpit(raw_predictions[i])
            gradients[i] = (p_i - y_true[i]) * sample_weight[i]
            hessians[i] = p_i * (1. - p_i) * sample_weight[i]


def _update_gradients_hessians_categorical_crossentropy(
        G_H_DTYPE_C [:, ::1] gradients,  # OUT
        G_H_DTYPE_C [:, ::1] hessians,  # OUT
        const Y_DTYPE_C [::1] y_true,  # IN
        const Y_DTYPE_C [:, ::1] raw_predictions,  # IN
        const Y_DTYPE_C [::1] sample_weight,  # IN
        int n_threads,  # IN
):
    cdef:
        int prediction_dim = raw_predictions.shape[0]
        int n_samples = raw_predictions.shape[1]
        int k  # class index
        int i  # sample index
        Y_DTYPE_C sw
        # p[i, k] is the probability that class(ith sample) == k.
        # It's the softmax of the raw predictions
        Y_DTYPE_C [:, ::1] p = np.empty(shape=(n_samples, prediction_dim))
        Y_DTYPE_C p_i_k

    if sample_weight is None:
        for i in prange(n_samples, schedule='static', nogil=True, num_threads=n_threads):
            # first compute softmaxes of sample i for each class
            for k in range(prediction_dim):
                p[i, k] = raw_predictions[k, i]  # prepare softmax
            _compute_softmax(p, i)
            # then update gradients and hessians
            for k in range(prediction_dim):
                p_i_k = p[i, k]
                gradients[k, i] = p_i_k - (y_true[i] == k)
                hessians[k, i] = p_i_k * (1. - p_i_k)
    else:
        for i in prange(n_samples, schedule='static', nogil=True, num_threads=n_threads):
            # first compute softmaxes of sample i for each class
            for k in range(prediction_dim):
                p[i, k] = raw_predictions[k, i]  # prepare softmax
            _compute_softmax(p, i)
            # then update gradients and hessians
            sw = sample_weight[i]
            for k in range(prediction_dim):
                p_i_k = p[i, k]
                gradients[k, i] = (p_i_k - (y_true[i] == k)) * sw
                hessians[k, i] = (p_i_k * (1. - p_i_k)) * sw


cdef inline void _compute_softmax(Y_DTYPE_C [:, ::1] p, const int i) nogil:
    """Compute softmaxes of values in p[i, :]."""
    # i needs to be passed (and stays constant) because otherwise Cython does
    # not generate optimal code

    cdef:
        Y_DTYPE_C max_value = p[i, 0]
        Y_DTYPE_C sum_exps = 0.
        unsigned int k
        unsigned prediction_dim = p.shape[1]

    # Compute max value of array for numerical stability
    for k in range(1, prediction_dim):
        if max_value < p[i, k]:
            max_value = p[i, k]

    for k in range(prediction_dim):
        p[i, k] = exp(p[i, k] - max_value)
        sum_exps += p[i, k]

    for k in range(prediction_dim):
        p[i, k] /= sum_exps


cdef inline Y_DTYPE_C _cexpit(const Y_DTYPE_C x) nogil:
    """Custom expit (logistic sigmoid function)"""
    return 1. / (1. + exp(-x))
