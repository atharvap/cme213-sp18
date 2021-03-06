#include <math_constants.h>

#include "BC.h"

/**
 * Calculates the next finite difference step given a
 * grid point and step lengths.
 *
 * @param curr Pointer to the grid point that should be updated.
 * @param width Number of grid points in the x dimension.
 * @param xcfl Courant number for x dimension.
 * @param ycfl Courant number for y dimension.
 * @returns Grid value of next timestep.
 */
template<int order>
__device__
float Stencil(const float* curr, int width, float xcfl, float ycfl) {
    switch(order) {
        case 2:
            return curr[0] + xcfl * (curr[-1] + curr[1] - 2.f * curr[0]) +
                   ycfl * (curr[width] + curr[-width] - 2.f * curr[0]);

        case 4:
            return curr[0] + xcfl * (- curr[2] + 16.f * curr[1] - 30.f * curr[0] +
                                     16.f * curr[-1] - curr[-2]) + ycfl * (- curr[2 * width] +
                                             16.f * curr[width] - 30.f * curr[0] + 16.f * curr[-width] -
                                             curr[-2 * width]);

        case 8:
            return curr[0] + xcfl * (-9.f * curr[4] + 128.f * curr[3] -
                                     1008.f * curr[2] + 8064.f * curr[1] - 14350.f * curr[0] +
                                     8064.f * curr[-1] - 1008.f * curr[-2] + 128.f * curr[-3] -
                                     9.f * curr[-4]) + ycfl * (-9.f * curr[4 * width] +
                                             128.f * curr[3 * width] - 1008.f * curr[2 * width] +
                                             8064.f * curr[width] - 14350.f * curr[0] +
                                             8064.f * curr[-width] - 1008.f * curr[-2 * width] +
                                             128.f * curr[-3 * width] - 9.f * curr[-4 * width]);

        default:
            printf("ERROR: Order %d not supported", order);
            return CUDART_NAN_F;
    }
}

/**
 * Kernel to propagate finite difference grid from the current
 * time point to the next.
 *
 * This kernel should be very simple and only use global memory.
 *
 * @param next[out] Next grid state.
 * @param curr Current grid state.
 * @param gx Number of grid points in the x dimension.
 * @param nx Number of grid points in the x dimension to which the full
 *           stencil can be applied (ie the number of points that are at least
 *           order/2 grid points away from the boundary).
 * @param ny Number of grid points in the y dimension to which th full
 *           stencil can be applied.
 * @param xcfl Courant number for x dimension.
 * @param ycfl Courant number for y dimension.
 */
template<int order>
__global__
void gpuStencil(float* next, const float* curr, int gx, int nx, int ny,
                float xcfl, float ycfl) {
    // TODO
    const uint tidx = blockDim.x*blockIdx.x + threadIdx.x;
    const uint tidy = blockDim.y*blockIdx.y + threadIdx.y;
    const uint borderSize = order/2;
    if (tidx < nx && tidy < ny) {
        const uint i = gx*(tidy + borderSize) + (tidx + borderSize);
        next[i] = Stencil<order>(&curr[i], gx, xcfl, ycfl);
    } 
}

/**
 * Propagates the finite difference 2D heat diffusion solver
 * using the gpuStencil kernel.
 *
 * Use this function to do necessary setup and propagate params.iters()
 * number of times.
 *
 * @param curr_grid The current state of the grid.
 * @param params Parameters for the finite difference computation.
 * @returns Time required for computation.
 */
double gpuComputation(Grid& curr_grid, const simParams& params) {

    boundary_conditions BC(params);

    Grid next_grid(curr_grid);

    // TODO: Declare variables/Compute parameters.
    int nx = params.nx();
    int ny = params.ny();
    int order = params.order();
    int gx = params.gx();
    float xcfl = params.xcfl();
    float ycfl = params.ycfl();

    const int thrX = 32;
    const int thrY = 6;
    dim3 threads(thrX, thrY);
    
    const int blX = (nx + thrX - 1)/thrX;
    const int blY = (ny + thrY - 1)/thrY;
    dim3 blocks(blX, blY);

    event_pair timer;
    start_timer(&timer);

    for(int i = 0; i < params.iters(); ++i) {

        // update the values on the boundary only
        BC.updateBC(next_grid.dGrid_, curr_grid.dGrid_);

        // TODO: Apply stencil.
        if (order == 2)
            gpuStencil<2><<<blocks,threads>>>(next_grid.dGrid_,
                                              curr_grid.dGrid_,
                                              gx, nx, ny,
                                              xcfl, ycfl);
        else if (order == 4)
            gpuStencil<4><<<blocks,threads>>>(next_grid.dGrid_,
                                              curr_grid.dGrid_,
                                              gx, nx, ny,
                                              xcfl, ycfl);
        else
            gpuStencil<8><<<blocks,threads>>>(next_grid.dGrid_,
                                              curr_grid.dGrid_,
                                              gx, nx, ny,
                                              xcfl, ycfl);

        check_launch("gpuStencil");

        Grid::swap(curr_grid, next_grid);
    }

    return stop_timer(&timer);
}


/**
 * Kernel to propagate finite difference grid from the current
 * time point to the next.
 *
 * This kernel should be optimized to compute finite difference updates
 * in blocks of size (blockDim.y * numYPerStep) * blockDim.x. Each thread
 * should calculate at most numYPerStep updates. It should still only use
 * global memory.
 *
 * @param next[out] Next grid state.
 * @param curr Current grid state.
 * @param gx Number of grid points in the x dimension.
 * @param nx Number of grid points in the x dimension to which the full
 *           stencil can be applied (ie the number of points that are at least
 *           order/2 grid points away from the boundary).
 * @param ny Number of grid points in the y dimension to which th full
 *           stencil can be applied.
 * @param xcfl Courant number for x dimension.
 * @param ycfl Courant number for y dimension.
 */
template<int order, int numYPerStep>
__global__
void gpuStencilLoop(float* next, const float* curr, int gx, int nx, int ny,
                    float xcfl, float ycfl) {
    // TODO
    const uint tidx = blockIdx.x*blockDim.x + threadIdx.x;
    uint tidy = numYPerStep*(blockIdx.y*blockDim.y) + threadIdx.y;

    const uint borderSize = (gx-nx)/2;

    for (int j = 0; j < numYPerStep; j++) {
        if ((tidy + j*blockDim.y)< ny && tidx < nx) {
            const uint i = gx*(tidy + j*blockDim.y + borderSize) + tidx + borderSize;
            next[i] = Stencil<order>(&curr[i], gx, xcfl, ycfl);
        }
    }
}

/**
 * Propagates the finite difference 2D heat diffusion solver
 * using the gpuStencilLoop kernel.
 *
 * Use this function to do necessary setup and propagate params.iters()
 * number of times.
 *
 * @param curr_grid The current state of the grid.
 * @param params Parameters for the finite difference computation.
 * @returns Time required for computation.
 */
double gpuComputationLoop(Grid& curr_grid, const simParams& params) {

    boundary_conditions BC(params);

    Grid next_grid(curr_grid);
    // TODO
    // TODO: Declare variables/Compute parameters.
    int nx = params.nx();
    int ny = params.ny();
    int order = params.order();
    int iters = params.iters();
    int gx = params.gx();
    float xcfl = params.xcfl();
    float ycfl = params.ycfl();

    const int numYPerStep = 6;
    const int thrX = 32;
    const int thrY = 6;
    dim3 threads(thrX, thrY);

    const int blX = (nx + thrX - 1)/thrX;
    int blY = (ny + thrY - 1)/thrY;
    blY = (blY + numYPerStep - 1)/numYPerStep;
    dim3 blocks(blX, blY);

    event_pair timer;
    start_timer(&timer);

    for(int i = 0; i < iters; ++i) {

        // update the values on the boundary only
        BC.updateBC(next_grid.dGrid_, curr_grid.dGrid_);

        if (order == 2)
            gpuStencilLoop<2,numYPerStep><<<blocks,threads>>>(next_grid.dGrid_,
                                                              curr_grid.dGrid_,
                                                              gx, nx, ny,
                                                              xcfl, ycfl);
        else if (order == 4)
            gpuStencilLoop<4,numYPerStep><<<blocks,threads>>>(next_grid.dGrid_,
                                                              curr_grid.dGrid_,
                                                              gx, nx, ny,
                                                              xcfl, ycfl);
        else
            gpuStencilLoop<8,numYPerStep><<<blocks,threads>>>(next_grid.dGrid_,
                                                              curr_grid.dGrid_,
                                                              gx, nx, ny,
                                                              xcfl, ycfl);
 
        check_launch("gpuStencilLoop");

        Grid::swap(curr_grid, next_grid);
    }

    return stop_timer(&timer);
}

/**
 * Kernel to propagate finite difference grid from the current
 * time point to the next.
 *
 * This kernel should be optimized to compute finite difference updates
 * in blocks of size side * side using shared memory.
 *
 * @param next[out] Next grid state.
 * @param curr Current grid state.
 * @param gx Number of grid points in the x dimension.
 * @param gy Number of grid points in the y dimension.
 * @param xcfl Courant number for x dimension.
 * @param ycfl Courant number for y dimension.
 */
template<int side, int order>
__global__
void gpuShared(float* next, const float* curr, int gx, int gy,
               float xcfl, float ycfl) {
    // TODO
}

/**
 * Propagates the finite difference 2D heat diffusion solver
 * using the gpuShared kernel.
 *
 * Use this function to do necessary setup and propagate params.iters()
 * number of times.
 *
 * @param curr_grid The current state of the grid.
 * @param params Parameters for the finite difference computation.
 * @returns Time required for computation.
 */
template<int order>
double gpuComputationShared(Grid& curr_grid, const simParams& params) {

    boundary_conditions BC(params);

    Grid next_grid(curr_grid);

    // TODO: Declare variables/Compute parameters.
    dim3 threads(0, 0);
    dim3 blocks(0, 0);

    event_pair timer;
    start_timer(&timer);

    for(int i = 0; i < params.iters(); ++i) {

        // update the values on the boundary only
        BC.updateBC(next_grid.dGrid_, curr_grid.dGrid_);

        // TODO: Apply stencil.

        check_launch("gpuShared");

        Grid::swap(curr_grid, next_grid);
    }

    return stop_timer(&timer);
}

