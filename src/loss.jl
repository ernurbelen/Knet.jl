# Loss Layers

abstract LossLayer <: Layer

# LossLayer has slightly different input/output behavior compared to regular layers:
# forw only records the outgoing y.
# back takes z, the desired output, and overwrites it with the loss gradient wrt y
# loss takes z, the desired output, and returns a loss value

for (ltype, lback, lloss) in (
                              (:QuadLoss, :quadlossback, :quadloss),
                              (:SoftLoss, :softlossback, :softloss),
                              (:LogpLoss, :logplossback, :logploss),
                              (:XentLoss, :xentlossback, :xentloss),
                              )
    @eval begin
        type $ltype <: LossLayer; y; $ltype()=new(); end
        forw(l::$ltype, y; o...)=(l.y=y)
        back(l::$ltype, z; returndx=true, o...)=(@assert issimilar(z,l.y); returndx && ($lback(l.y,z); z))
        loss(l::$ltype, z)=(@assert issimilar(z,l.y); $lloss(l.y,z))
        $lback(y::KUdense, z::KUdense)=$lback(y.arr, z.arr)
        $lloss(y::KUdense, z::KUdense)=$lloss(y.arr, z.arr)
        $lloss(y::CudaArray, z::CudaArray)=$lloss(to_host(y), to_host(z))
    end
end


### QUADLOSS:

# Quadratic loss:
# l.y stores the model output.
# z is the desired output.
# Overwrites z with the gradient of quadratic loss wrt y, i.e. y-z
# J = 0.5*sum((yi-zi)^2)
# dJ/dy = y-z

quadloss(y::Array, z::Array)=(cost=zero(Float64); for i=1:length(z); cost += (y[i]-z[i])^2; end; 0.5*cost/ccount(z))
quadlossback(y::Array, z::Array)=(nx=ccount(z); for i=1:length(z); z[i] = (y[i]-z[i])/nx; end)
GPU && (quadlossback(y::CudaArray, z::CudaArray)=cudnnTransformTensor(1/ccount(y), y, -1/ccount(y), z))


### SOFTLOSS: 

# Cross entropy loss to use after the Soft layer.
# l.y should have normalized probabilities output by the model.
# p has normalized probabilities from the answer key.
# Normalization is across the last dimension, i.e. sum(p[:,...,:,i])==1
# Overwrites p with the gradient of the loss wrt y, i.e. 1-p/y

# Math:
#
# J = -Σ pi log yi		;; loss function
#   = -Σ pi log (yi/Σyj)	;; should make normalization explicit
#   = (-Σ pi log yi) + Σ pi log Σ yj
#   = (-Σ pi log yi) + log Σ yj
#
# ∂J/∂yk = -pk/yk + (1/Σ yj)
#        = -pk/yk + 1
#
# z = wx			;; z is the input to the soft layer
# yi = (exp zi) / (Σ exp zj)	;; y is the output of the soft layer
# ∂yi/∂zk = [(i=k)(exp zi)(Σ exp zj) - (exp zi)(exp zk)] / (Σ exp zj)^2
#         = (i=k) yi - yi yk
# ∂J/∂zk = Σ (∂J/∂yi)(∂yi/∂zk)	;; derivative wrt the input z
#        = Σ (1-pi/yi)((i=k) yi - yi yk)
#        = Σ ((i=k) yi - yi yk - (i=k) pi + pi yk)
#        = yk - pk - yk Σ (yi - pi)
#        = yk - pk

softloss(y::Array,p::Array)=(cost=zero(Float64); for i=1:length(p); cost -= (p[i]*log(y[i])); end; cost/ccount(p))
softlossback(y::Array,p::Array)=(nx=ccount(p); for i=1:length(p); p[i] = ((y[i]-p[i])/y[i])/nx; end)
GPU && (softlossback(y::CudaArray{Float32}, p::CudaArray{Float32})=ccall((:softloss32,libkunet),Void,(Cint,Cdouble,Ptr{Cfloat},Ptr{Cfloat}),length(p),1/ccount(p),y,p))
GPU && (softlossback(y::CudaArray{Float64}, p::CudaArray{Float64})=ccall((:softloss64,libkunet),Void,(Cint,Cdouble,Ptr{Cdouble},Ptr{Cdouble}),length(p),1/ccount(p),y,p))


### LOGPLOSS:

# Cross entropy loss to use after the Logp layer.
# l.y should be normalized log probabilities output by the model.
# p has normalized probabilities from the answer key.
# Normalization is across the last dimension, i.e. sum(p[:,...,:,i])==1
# Overwrites p with the gradient of the loss wrt y, i.e. exp(y)-p:
#
# z = sum(exp(y))   ;; normalization constant (should be 1 here)
# q = exp(y)/z      ;; model probabilities
# logq = y - logz   ;; model (normalized) log prob
# dlogz/dy = q      
#
# J = (1/N) Σ[nc] -p[nc]*logq[nc]  ;; n=1..N: instance, c=1..C: class
#   = (1/N) Σ[nc] -p[nc]*(y[nc]-logz[n])
#   = (1/N) ((Σ[n] logz[n]) - (Σ[nc] p[nc]*y[nc]))
#   = (1/N) (Σ[nc] -p[nc]*y[nc])   ;; all logz are 0
#
# dJ/dy[md] = (1/N) (q[md] - p[md])

logploss(y::Array, p::Array)=(nx = ccount(p); cost = zero(Float64); for i=1:length(p); cost -= (p[i]*y[i]); end; cost/nx)
logplossback(y::Array, p::Array)=(nx = ccount(p); for i=1:length(p); p[i] = (exp(y[i])-p[i])/nx; end)
GPU && (logplossback(y::CudaArray{Float32}, p::CudaArray{Float32})=ccall((:logploss32,libkunet),Void,(Cint,Cdouble,Ptr{Cfloat},Ptr{Cfloat}),length(p),1/ccount(p),y,p))
GPU && (logplossback(y::CudaArray{Float64}, p::CudaArray{Float64})=ccall((:logploss64,libkunet),Void,(Cint,Cdouble,Ptr{Cdouble},Ptr{Cdouble}),length(p),1/ccount(p),y,p))


### XENTLOSS:

# Cross entropy loss to use after an unnormalized layer.
# l.y is treated as unnormalized log probabilities output by the model.
# p has normalized probabilities from the answer key.
# Normalization is across the last dimension, i.e. sum(p[:,...,:,i])==1
# Overwrites p with the gradient of the loss wrt y, i.e. q-p:
#
# z = sum(exp(y))   ;; normalization constant
# q = exp(y)/z      ;; model probabilities
# logq = y - logz   ;; model (normalized) log prob
# dlogz/dy = q      
#
# J = (1/N) Σ[nc] -p[nc]*logq[nc]  ;; n=1..N: instance, c=1..C: class
#   = (1/N) Σ[nc] -p[nc]*(y[nc]-logz[n])
#   = (1/N) ((Σ[n] logz[n]) - (Σ[nc] p[nc]*y[nc]))
#
# dJ/dy[md] = (1/N) (q[md] - p[md])

function xentloss(y::Array, p::Array)
    cost = zero(Float64)
    (nd,nx) = size2(p)
    for j=1:nx
        i1=(j-1)*nd+1; i2=j*nd
        z = sumpy = zero(Float64)
        ymax = typemin(eltype(y))
        for i=i1:i2; y[i] > ymax && (ymax = y[i]); end
        for i=i1:i2; yi=y[i]-ymax; z += exp(yi); sumpy += p[i]*yi; end
        cost += (log(z) - sumpy)
    end
    return cost/nx
end

function xentlossback(y::Array, p::Array)
    (nd,nx) = size2(p)
    # cuda cannot handle allocation, we will overwrite y for compatibility
    # qz = similar(p, nd)
    for j=1:nx
        i1=(j-1)*nd+1; i2=j*nd
        z = zero(Float64)
        ymax = typemin(eltype(y)) # subtract ymax for numerical stability
        for i=i1:i2; y[i] > ymax && (ymax = y[i]); end
        for i=i1:i2; y[i] = exp(y[i]-ymax); z+=y[i]; end
        for i=i1:i2; y[i]/=z; p[i] = (y[i] - p[i])/nx; end
        #for i=i1:i2; z += (qz[i-i1+1] = exp(y[i]-ymax)); end
        #for i=i1:i2; p[i] = (qz[i-i1+1]/z - p[i])/nx; end
    end
    return p
end

GPU && (xentlossback(y::CudaArray{Float32}, p::CudaArray{Float32})=((nd,nx)=size2(p);ccall((:xentloss32,libkunet),Void,(Cint,Cint,Ptr{Cfloat},Ptr{Cfloat}),nd,nx,y,p)))
GPU && (xentlossback(y::CudaArray{Float64}, p::CudaArray{Float64})=((nd,nx)=size2(p);ccall((:xentloss64,libkunet),Void,(Cint,Cint,Ptr{Cdouble},Ptr{Cdouble}),nd,nx,y,p)))

