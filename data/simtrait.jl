# ========================================================================
# Code for simulating binary traits with environmental exposure from UKBB data
# ========================================================================
using CSV, DataFrames, SnpArrays, DataFramesMeta, StatsBase, LinearAlgebra, Distributions, CodecZlib

# ------------------------------------------------------------------------
# Initialize parameters
# ------------------------------------------------------------------------
# Assign default command-line arguments
const ARGS_ = isempty(ARGS) ? ["0.3", "0.3", "0.05", "10000", "0.003", "50000", "data/"] : ARGS

# Fraction of variance due to polygenic additive effect (logit scale)
h2_g = parse(Float64, ARGS_[1])

# Fraction of residual variance due to unobserved shared environmental effect (logit scale)
h2_d = parse(Float64, ARGS_[2])

# Prevalence
pi0 = parse(Float64, ARGS_[3])	

# Number of snps to randomly select accros genome
p = parse(Int, ARGS_[4])

# Percentage of causal SNPs
c = parse(Float64, ARGS_[5])

# Number of snps to use for GRM estimation
if ARGS_[6] != "ALL" p_kin = parse(Int, ARGS_[6]) end

# ------------------------------------------------------------------------
# Load the covariate file
# ------------------------------------------------------------------------
# Read plink fam file
samples = @chain CSV.read("UKBB.fam", DataFrame; header = false) begin  
    @select!(:FID = :Column1, :IID = :Column2)
end

# Caucasian individuals
caucasians = @chain CSV.read("include_Caucasian.txt", DataFrame; header = false) begin
    @select!(:FID = :Column1, :IID = :Column2)
    @transform(:ETHNICITY = "Caucasian", :CAUCASIAN = 1)
end
    
# Non-caucasian individuals
non_caucasians = @chain CSV.read("include_notCaucasian.txt", DataFrame; header = false) begin
    @select!(:FID = :Column1, :IID = :Column2)
    @transform!(:ETHNICITY = "Non-Caucasian", :CAUCASIAN = 0)
end

# Combine into a DataFrame
dat = @chain CSV.read("covars_full.txt", DataFrame) begin
    @select!(:FID, :IID, :SEX, :AGE, :PCA1, :PCA2, :PCA3, :PCA4, :PCA5, :PCA6, :PCA7, :PCA8, :PCA9, :PCA10)
	rightjoin(samples, on = [:FID, :IID])
	leftjoin(vcat(caucasians, non_caucasians), on = [:FID, :IID])
end	    	  
n = size(dat, 1)

#-------------------------------------------------------------------------
# Load genotype Data
#-------------------------------------------------------------------------
# Read plink bim file
UKBB = SnpArray("UKBB.bed")

# Sample p candidate SNPs randomly accross genome, convert to additive model, scale and impute
snp_inds = sample(axes(UKBB, 2), p, replace = false, ordered = true)
G = convert(Matrix{Float64}, @view(UKBB[:, snp_inds]), center = true, scale = true, impute = true)

# Save filtered plink file
rowmask, colmask = trues(n), [col in snp_inds for col in 1:size(UKBB, 2)]
SnpArrays.filter("UKBB", rowmask, colmask, des = ARGS_[7] * "geno")

if ARGS_[6] != "ALL"
    # Estimate GRM
    grm_inds = sample(setdiff(axes(UKBB, 2), snp_inds), p_kin, replace = false, ordered = true)
    GRM = 2 * grm(UKBB, cinds = grm_inds)

    # Make sure GRM is posdef
    xi = 1e-4
    while !isposdef(GRM)
        GRM = GRM + xi * Diagonal(ones(n))
        xi = 10 * xi
    end

    # Save GRM in compressed file
    open(GzipCompressorStream, ARGS_[7] * "grm.txt.gz", "w") do stream
        CSV.write(stream, DataFrame(GRM, :auto))
    end
end

# ------------------------------------------------------------------------
# Simulate phenotypes
# ------------------------------------------------------------------------
# Variance components
sigma2_e = pi^2 / 3 + log(1.3)^2 * var(dat.SEX .== "1") + log(1.05)^2 * var((dat.AGE .- 56) / 10)
sigma2_g = ARGS_[6] != "ALL" ? 1/2 * h2_g / (1 - h2_g - h2_d) * sigma2_e : h2_g / (1 - h2_g - h2_d) * sigma2_e
sigma2_d = h2_d / (1 - h2_g - h2_d) * sigma2_e

# Simulate fixed effects for randomly sampled causal snps
W = zeros(p)
s = sample(1:p, Integer(round(p*c)), replace = false)
W[s] .= sigma2_g/length(s)
beta = rand.([Normal(0, sqrt(W[i])) for i in 1:p])

# Set fixed effect for dichotomous environmental effect
gamma = sqrt(4 * sigma2_d)

# Simulate random effects
b = ARGS_[6] != "ALL" ? rand(MvNormal(sigma2_g * GRM)) : zeros(n)

# Simulate binary traits
logit(x) = log(x / (1 - x))
expit(x) = exp(x) / (1 + exp(x))
final_dat = @chain dat begin
	@transform!(:logit_pi = logit(pi0) .+ gamma * :CAUCASIAN - log(1.3) * :SEX + log(1.05) * ((:AGE .- 56) / 10) + G * beta + b)
    @transform!(:pi = expit.(:logit_pi))
    @transform(:y = rand.([Binomial(1, :pi[i]) for i in 1:n]))
    select!(Not([:pi, :logit_pi, :ETHNICITY]))
end

#----------------------
# Write csv files
#---------------------
# CSV file containing covariates
CSV.write(ARGS_[7] * "covariate.txt", final_dat)

# CSV file containing maf and simulated effect for each SNP
df = SnpData("UKBB").snp_info[snp_inds, [1,2,4]]
df.beta = beta
df.maf0 = maf(@view(UKBB[dat.CAUCASIAN .== 0, snp_inds]))
df.maf1 = maf(@view(UKBB[dat.CAUCASIAN .== 1, snp_inds]))
CSV.write(ARGS_[7] * "betas.txt", df)