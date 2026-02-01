# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Statistical analysis for benchmark results.

Provides confidence intervals, coefficient of variation, stability checks,
and regression detection using scipy.stats.
"""

from typing import Dict, List, Tuple

import numpy as np
from scipy import stats


def confidence_interval(
    samples: List[float],
    confidence: float = 0.95,
) -> Tuple[float, float]:
    """Calculate confidence interval for the mean.

    Uses scipy.stats.t.interval for proper t-distribution based CI.

    Args:
        samples: List of sample values.
        confidence: Confidence level (default 0.95 for 95% CI).

    Returns:
        Tuple of (low, high) bounds for the confidence interval.

    Raises:
        ValueError: If fewer than 2 samples provided.
    """
    if len(samples) < 2:
        raise ValueError("Need at least 2 samples for confidence interval")

    n = len(samples)
    mean = np.mean(samples)
    se = stats.sem(samples)  # Standard error of mean

    # Handle zero variance case
    if se == 0:
        return (mean, mean)

    # t.interval returns (low, high) for given confidence
    ci = stats.t.interval(confidence, df=n - 1, loc=mean, scale=se)
    return (float(ci[0]), float(ci[1]))


def coefficient_of_variation(samples: List[float]) -> float:
    """Calculate coefficient of variation (CV).

    CV = std / mean, measuring relative variability.

    Args:
        samples: List of sample values.

    Returns:
        Coefficient of variation (0.1 = 10% variability).

    Raises:
        ValueError: If fewer than 2 samples or mean is zero.
    """
    if len(samples) < 2:
        raise ValueError("Need at least 2 samples for CV calculation")

    mean = np.mean(samples)
    if mean == 0:
        return 0.0  # Avoid division by zero

    std = np.std(samples, ddof=1)  # Sample standard deviation
    return float(std / mean)


def is_stable(samples: List[float], threshold_cv: float = 0.10) -> bool:
    """Check if samples are stable (CV below threshold).

    Args:
        samples: List of sample values.
        threshold_cv: Maximum acceptable CV (default 0.10 = 10%).

    Returns:
        True if CV < threshold, indicating stable measurements.
    """
    if len(samples) < 2:
        return False

    cv = coefficient_of_variation(samples)
    return cv < threshold_cv


def detect_regression(
    baseline: List[float],
    current: List[float],
    alpha: float = 0.05,
) -> Tuple[bool, float]:
    """Detect statistically significant performance regression.

    Uses Welch's t-test (does not assume equal variances) with
    alternative='greater' for latency (higher = regression).

    Args:
        baseline: Baseline samples (e.g., previous version latencies).
        current: Current samples (e.g., new version latencies).
        alpha: Significance level (default 0.05 for 5%).

    Returns:
        Tuple of (is_regression, p_value).
        is_regression is True if current is significantly greater than baseline.

    Raises:
        ValueError: If either list has fewer than 2 samples.
    """
    if len(baseline) < 2:
        raise ValueError("Need at least 2 baseline samples")
    if len(current) < 2:
        raise ValueError("Need at least 2 current samples")

    # Welch's t-test (equal_var=False)
    # alternative='greater' means we test if current > baseline (regression)
    stat, p_value = stats.ttest_ind(
        current,
        baseline,
        equal_var=False,
        alternative='greater',
    )

    is_regression = p_value < alpha
    return (is_regression, float(p_value))


def summarize(samples: List[float]) -> Dict:
    """Generate summary statistics for samples.

    Args:
        samples: List of sample values.

    Returns:
        Dict with mean, std, cv, ci_low, ci_high, min, max, count.

    Raises:
        ValueError: If fewer than 2 samples.
    """
    if len(samples) < 2:
        raise ValueError("Need at least 2 samples for summary")

    mean = float(np.mean(samples))
    std = float(np.std(samples, ddof=1))
    cv = coefficient_of_variation(samples)
    ci_low, ci_high = confidence_interval(samples)

    return {
        "mean": mean,
        "std": std,
        "cv": cv,
        "ci_low": ci_low,
        "ci_high": ci_high,
        "min": float(np.min(samples)),
        "max": float(np.max(samples)),
        "count": len(samples),
    }
